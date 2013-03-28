require "set"

require "log4r"

require "vagrant/util/is_port_open"

module Vagrant
  module Action
    module Builtin
      # This middleware class will detect and handle collisions with
      # forwarded ports, whether that means raising an error or repairing
      # them automatically.
      #
      # Parameters it takes from the environment hash:
      #
      #   * `:port_collision_repair` - If true, it will attempt to repair
      #     port collisions. If false, it will raise an exception when
      #     there is a collision.
      #
      #   * `:port_collision_extra_in_use` - An array of ports that are
      #     considered in use.
      #
      #   * `:port_collision_remap` - A hash remapping certain host ports
      #     to other host ports.
      #
      class HandleForwardedPortCollisions
        include Util::IsPortOpen

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant::action::builtin::handle_port_collisions")
        end

        def call(env)
          @logger.info("Detecting any forwarded port collisions...")

          # Get the extra ports we consider in use
          extra_in_use = env[:port_collision_extra_in_use] || []

          # Get the remap
          remap = env[:port_collision_remap] || {}

          # Determine the handler we'll use if we have any port collisions
          repair = !!env[:port_collision_repair]

          # Log out some of our parameters
          @logger.debug("Extra in use: #{extra_in_use.inspect}")
          @logger.debug("Remap: #{remap.inspect}")
          @logger.debug("Repair: #{repair.inspect}")

          # Determine a list of usable ports for repair
          usable_ports = Set.new(env[:machine].config.vm.usable_port_range)
          usable_ports.subtract(extra_in_use)

          # Pass one, remove all defined host ports from usable ports
          with_forwarded_ports(env) do |options|
            usable_ports.delete(options[:host])
          end

          # Pass two, detect/handle any collisions
          with_forwarded_ports(env) do |options|
            guest_port = options[:guest]
            host_port  = options[:host]

            if remap[host_port]
              remap_port = remap[host_port]
              @logger.debug("Remap port override: #{host_port} => #{remap_port}")
              host_port = remap_port
            end

            # If the port is open (listening for TCP connections)
            if extra_in_use.include?(host_port) || is_port_open?("127.0.0.1", host_port)
              if !repair
                raise Errors::ForwardPortCollision,
                  :guest_port => guest_port.to_s,
                  :host_port  => host_port.to_s
              end

              @logger.info("Attempting to repair FP collision: #{host_port}")

              # If we have no usable ports then we can't repair
              if usable_ports.empty?
                raise Errors::ForwardPortAutolistEmpty,
                  :vm_name    => env[:machine].name,
                  :guest_port => guest_port.to_s,
                  :host_port  => host_port.to_s
              end

              # Attempt to repair the forwarded port
              repaired_port = usable_ports.to_a.sort[0]
              usable_ports.delete(repaired_port)

              # Modify the args in place
              options[:host] = repaired_port

              @logger.info("Repaired FP collision: #{host_port} to #{repaired_port}")

              # Notify the user
              env[:ui].info(I18n.t("vagrant.actions.vm.forward_ports.fixed_collision",
                                   :host_port  => host_port.to_s,
                                   :guest_port => guest_port.to_s,
                                   :new_port   => repaired_port.to_s))
            end
          end

          @app.call(env)
        end

        protected

        def with_forwarded_ports(env)
          env[:machine].config.vm.networks.each do |type, options|
            # Ignore anything but forwarded ports
            next if type != :forwarded_port

            yield options
          end
        end
      end
    end
  end
end