require "../exchange"
require "../consistent_hasher.cr"

module AvalancheMQ
  class ConsistentHashExchange < Exchange
    @hasher = ConsistentHasher(Destination).new

    def type : String
      "x-consistent-hash"
    end

    private def weight(routing_key : String) : UInt32
      routing_key.to_u32? || raise Error::PreconditionFailed.new("Routing key must to be a number")
    end

    private def hash_key(routing_key : String, headers : AMQP::Table?)
      return routing_key unless @arguments["x-hash-on"]?.as?(String)
      return "" if headers.nil?
      hash_on = @arguments["x-hash-on"].as(String)
      headers[hash_on].as?(String) || raise Error::PreconditionFailed.new("Routing header must be string")
    end

    def bind(destination : Destination, routing_key : String, headers : Hash(String, AMQP::Field)?)
      w = weight(routing_key)
      @hasher.add(destination.name, w, destination)
      case destination
      when Queue
        @queue_bindings[{routing_key, headers}] << destination
      when Exchange
        @exchange_bindings[{routing_key, headers}] << destination
      end
      after_bind(destination, routing_key, headers)
    end

    def unbind(destination : Destination, routing_key : String, headers : Hash(String, AMQP::Field)?)
      w = weight(routing_key)
      case destination
      when Queue
        @queue_bindings[{routing_key, headers}].delete destination
      when Exchange
        @exchange_bindings[{routing_key, headers}].delete destination
      end
      @hasher.remove(destination.name, w)
    end

    def do_queue_matches(routing_key : String, headers : AMQP::Table?, &blk : Queue -> _)
      key = hash_key(routing_key, headers)
      case dest = @hasher.get(key)
      when Queue
        yield dest.as(Queue)
      end
    end

    def do_exchange_matches(routing_key : String, headers : AMQP::Table?, &blk : Exchange -> _)
      key = hash_key(routing_key, headers)
      case dest = @hasher.get(key)
      when Exchange
        yield dest.as(Exchange)
      end
    end
  end
end