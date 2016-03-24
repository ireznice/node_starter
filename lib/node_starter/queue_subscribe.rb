require 'multi_json'

require 'node_starter/starter'
require 'node_starter/consumer'
require 'node_starter/shutdown_consumer'

module NodeStarter
  # class for receiving start node messages
  class QueueSubscribe
    def initialize
      @consumer = NodeStarter::Consumer.new
      @shutdown_consumer = NodeStarter::ShutdownConsumer.new
      @reporting_publisher = NodeStarter::ReportingPublisher.new
    end

    def start_listening
      @consumer.setup
      @shutdown_consumer.setup
      @reporting_publisher.setup

      subscribe_stater_queue
      subscribe_killer_queue
    end

    def stop_listening
      NodeStarter.logger.info('Stopping listening. Bye, bye.')
      @consumer.close_connection
      @shutdown_consumer.close_connection
    end

    private

    def subscribe_stater_queue
      @consumer.subscribe do |delivery_info, _metadata, payload|
        run delivery_info, payload
      end
    end

    def subscribe_killer_queue
      @shutdown_consumer.subscribe do |delivery_info, _metadata, payload|
        stop delivery_info, payload
      end
    end

    def run(delivery_info, payload)
      params = nil
      begin
        params = JSON.parse(delivery_info, payload)

        NodeStarter.logger.info("Received START with build_id: #{params['build_id']}")

        starter = NodeStarter::Starter.new(
          params['build_id'], params['config'], params['enqueue_data'], params['node_api_uri'])

        @reporting_publisher.receive(params['build_id'])
        starter.start_node_process
        @consumer.ack(delivery_info)
        @shutdown_consumer.register_node(params['build_id'])
        @reporting_publisher.start(params['build_id'])
        wait_for_node(starter, params['build_id'])
      rescue => e
        NodeStarter.logger.error "Node #{params['build_id']} spawn failed: #{e}"

        @consumer.reject(delivery_info, true)
      end
    end

    def wait_for_node(starter, build_id)
      Thread.new do
        begin
          starter.wait_node_process
        ensure
          @shutdown_consumer.unregister_node(build_id)
        end
      end
    end

    def stop(delivery_info, payload)
      NodeStarter.logger.info("Received kill command: #{delivery_info[:routing_key]}")

      begin
        build_id = delivery_info[:routing_key].to_s
        build_id.slice!('cmd.')

        params = JSON.parse(payload)

        stopped_by = params['stopped_by']

        killer = NodeStarter::Killer.new build_id, stopped_by
        killer.shutdown_by_api
        @shutdown_consumer.ack delivery_info
      rescue JSON::ParserError
        NodeStarter.logger.error "Node stop input incorrect. Message nacked. input: #{payload}"
        @shutdown_consumer.reject(delivery_info, false)
      rescue => e
        NodeStarter.logger.error "Node stop failed: #{e}"
        @shutdown_consumer.reject(delivery_info, false)
      end

      Thread.new do
        mins = NodeStarter.config.shutdown_node_wait_in_minutes
        NodeStarter.logger.debug(
          "Waiting #{mins} minutes before starting killing node #{build_id}")
        sleep mins.minutes

        killer.watch_process
      end
    end
  end
end
