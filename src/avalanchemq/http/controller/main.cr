require "../controller"
require "../../version"

module AvalancheMQ
  module HTTP
    module StatsHelpers
      def add_logs!(logs_a, logs_b)
        a_size = logs_a.size
        b_dup = logs_b.dup
        logs_a.reverse!.map! do |a|
          b = b_dup.pop?
          b ? (a + b) : a
        end.reverse!
        while b_dup.size > 0
          if a_size < logs_b.size
            logs_a.unshift(b_dup.pop)
          else
            logs_a.push(b_dup.pop)
          end
        end
        logs_a
      end

      private def add_logs(logs_a, logs_b)
        add_logs!(logs_a.dup, logs_b)
      end
    end

    class MainController < Controller
      include StatsHelpers
      QUEUE_STATS = %w(ack deliver get publish redeliver reject)

      private def register_routes
        get "/api/overview" do |context, _params|
          x_vhost = context.request.headers["x-vhost"]?
          channels, connections, exchanges, queues, consumers, ready, unacked = 0, 0, 0, 0, 0, 0, 0
          recv_rate, send_rate = 0, 0
          ready_log = Array(UInt32).new(AvalancheMQ::Config.instance.stats_log_size)
          unacked_log = Array(UInt32).new(AvalancheMQ::Config.instance.stats_log_size)
          recv_rate_log = Array(Float32).new(AvalancheMQ::Config.instance.stats_log_size)
          send_rate_log = Array(Float32).new(AvalancheMQ::Config.instance.stats_log_size)
          {% for name in QUEUE_STATS %}
          {{name.id}}_rate = 0_f32
          {{name.id}}_log = Array(Float32).new(AvalancheMQ::Config.instance.stats_log_size)
          {% end %}

          vhosts(user(context)).each do |vhost|
            next unless x_vhost.nil? || vhost.name == x_vhost
            vhost_connections = @amqp_server.connections.select { |c| c.vhost.name == vhost.name }
            connections += vhost_connections.size
            vhost_connections.each do |c|
              channels += c.channels.size
              consumers += c.channels.values.reduce(0) { |memo, i| memo + i.consumers.size }
              recv_rate += c.stats_details[:recv_oct_details][:rate]
              send_rate += c.stats_details[:send_oct_details][:rate]
              add_logs!(recv_rate_log, c.stats_details[:recv_oct_details][:log])
              add_logs!(send_rate_log, c.stats_details[:send_oct_details][:log])
            end
            exchanges += vhost.exchanges.size
            queues += vhost.queues.size
            vhost.queues.each_value do |q|
              ready += q.message_count
              unacked += q.unacked_count
              add_logs!(ready_log, q.message_count_log)
              add_logs!(unacked_log, q.unacked_count_log)
              {% for name in QUEUE_STATS %}
              {{name.id}}_rate += q.stats_details[:{{name.id}}_details][:rate]
              add_logs!({{name.id}}_log, q.stats_details[:{{name.id}}_details][:log])
              {% end %}
            end
          end

          {
            avalanchemq_version: AvalancheMQ::VERSION,
            object_totals:       {
              channels:    channels,
              connections: connections,
              consumers:   consumers,
              exchanges:   exchanges,
              queues:      queues,
            },
            queue_totals: {
              messages:             ready + unacked,
              messages_ready:       ready,
              messages_unacked:     unacked,
              messages_log:         add_logs(ready_log, unacked_log),
              messages_ready_log:   ready_log,
              messages_unacked_log: unacked_log,
            },
            recv_oct_details: {
              rate: recv_rate,
              log:  recv_rate_log,
            },
            send_oct_details: {
              rate: send_rate,
              log:  send_rate_log,
            },
            message_stats: {% begin %} {
              {% for name in QUEUE_STATS %}
              {{name.id}}_details: {
                rate: {{name.id}}_rate,
                log: {{name.id}}_log,
              },
            {% end %} } {% end %},
            listeners:      @amqp_server.listeners,
            exchange_types: VHost::EXCHANGE_TYPES.map { |name| {name: name} },
          }.to_json(context.response)
          context
        end

        get "/api/whoami" do |context, _params|
          user(context).user_details.to_json(context.response)
          context
        end

        get "/api/aliveness-test/:vhost" do |context, params|
          with_vhost(context, params) do |vhost|
            @amqp_server.vhosts[vhost].declare_queue("aliveness-test", false, false)
            @amqp_server.vhosts[vhost].bind_queue("aliveness-test", "amq.direct", "aliveness-test")
            msg = Message.new(Time.utc_now.to_unix_ms,
              "amq.direct",
              "aliveness-test",
              AMQP::Properties.new,
              4_u64,
              IO::Memory.new("test"))
            ok = @amqp_server.vhosts[vhost].publish(msg)
            env = @amqp_server.vhosts[vhost].queues["aliveness-test"].basic_get(true)
            ok = ok && env && env.message.body_io.read_string(env.message.size) == "test"
            {status: ok ? "ok" : "failed"}.to_json(context.response)
          end
        end

        get "/api/shovels" do |context, _params|
          query = query_params(context)
          page(query, vhosts(user(context)).flat_map { |vhost| vhost.shovels.not_nil!.values })
            .to_json(context.response)
          context
        end

        get "/api/shovels/:vhost" do |context, params|
          query = query_params(context)
          with_vhost(context, params) do |vhost|
            page(query, @amqp_server.vhosts[vhost].shovels.not_nil!.values)
              .to_json(context.response)
          end
        end

        get "/api/federation-links" do |context, _params|
          links = [] of Federation::Upstream::Link
          query = query_params(context)
          vhosts(user(context)).each do |vhost|
            vhost.upstreams.not_nil!.each do |upstream|
              links.concat(upstream.links.values)
            end
          end
          page(query, links).to_json(context.response)
          context
        end

        get "/api/federation-links/:vhost" do |context, params|
          links = [] of Federation::Upstream::Link
          query = query_params(context)
          with_vhost(context, params) do |vhost|
            @amqp_server.vhosts[vhost].upstreams.not_nil!.each do |upstream|
              links.concat(upstream.links.values)
            end
            page(query, links).to_json(context.response)
          end
        end
      end
    end
  end
end
