require 'raven/base'
require 'English'

module Raven
  # A copy of Raven's base module class methods, minus some of the integration
  # and global hooks since it's meant to be used explicitly. Useful for
  # sending errors to multiple sentry projects in a large application.
  #
  # @example
  #   class Foo
  #     def initialize
  #       @other_raven = Raven::Instance.new
  #       @other_raven.configure do |config|
  #         config.server = 'http://...'
  #       end
  #     end
  #
  #     def foo
  #       # ...
  #     rescue => e
  #       @other_raven.capture_exception(e)
  #     end
  #   end
  class Instance
    # The client object is responsible for delivering formatted data to the
    # Sentry server. Must respond to #send. See Raven::Client.
    attr_writer :client

    # A Raven configuration object. Must act like a hash and return sensible
    # values for all Raven configuration options. See Raven::Configuration.
    attr_writer :configuration

    def initialize(context = nil)
      @context = @explicit_context = context
    end

    def context
      if @explicit_context
        @context ||= Context.new
      else
        Context.current
      end
    end

    def logger
      @logger ||= Logger.new
    end

    # The configuration object.
    # @see Raven.configure
    def configuration
      @configuration ||= Configuration.new
    end

    # The client object is responsible for delivering formatted data to the
    # Sentry server.
    def client
      @client ||= Client.new(configuration)
    end

    # Tell the log that the client is good to go
    def report_status
      return if configuration.silence_ready
      if configuration.capture_in_current_environment?
        logger.info "Raven #{VERSION} ready to catch errors"
      else
        logger.info "Raven #{VERSION} configured not to capture errors."
      end
    end

    # Call this method to modify defaults in your initializers.
    #
    # @example
    #   Raven.configure do |config|
    #     config.server = 'http://...'
    #   end
    def configure
      yield(configuration) if block_given?

      self.client = Client.new(configuration)
      report_status
      client
    end

    # Send an event to the configured Sentry server
    #
    # @example
    #   evt = Raven::Event.new(:message => "An error")
    #   Raven.send_event(evt)
    def send_event(event)
      client.send_event(event)
    end

    # Capture and process any exceptions from the given block.
    #
    # @example
    #   Raven.capture do
    #     MyApp.run
    #   end
    def capture(options = {})
      if block_given?
        begin
          yield
        rescue Error
          raise # Don't capture Raven errors
        rescue Exception => e
          capture_type(e, options)
          raise
        end
      else
        install_at_exit_hook(options)
      end
    end

    def capture_type(obj, options = {})
      unless configuration.capture_allowed?(obj)
        Raven.logger.debug("#{obj} excluded from capture due to environment or should_capture callback")
        return false
      end

      message_or_exc = obj.is_a?(String) ? "message" : "exception"
      if (evt = Event.send("from_" + message_or_exc, obj, options))
        yield evt if block_given?
        if configuration.async?
          configuration.async.call(evt)
        else
          send_event(evt)
        end
        Thread.current["sentry_#{object_id}_last_event_id".to_sym] = evt.id
        evt
      end
    end

    def last_event_id
      Thread.current["sentry_#{object_id}_last_event_id".to_sym]
    end

    # Provides extra context to the exception prior to it being handled by
    # Raven. An exception can have multiple annotations, which are merged
    # together.
    #
    # The options (annotation) is treated the same as the ``options``
    # parameter to ``capture_exception`` or ``Event.from_exception``, and
    # can contain the same ``:user``, ``:tags``, etc. options as these
    # methods.
    #
    # These will be merged with the ``options`` parameter to
    # ``Event.from_exception`` at the top of execution.
    #
    # @example
    #   begin
    #     raise "Hello"
    #   rescue => exc
    #     Raven.annotate_exception(exc, :user => { 'id' => 1,
    #                              'email' => 'foo@example.com' })
    #   end
    def annotate_exception(exc, options = {})
      notes = (exc.instance_variable_defined?(:@__raven_context) && exc.instance_variable_get(:@__raven_context)) || {}
      notes.merge!(options)
      exc.instance_variable_set(:@__raven_context, notes)
      exc
    end

    # Bind user context. Merges with existing context (if any).
    #
    # It is recommending that you send at least the ``id`` and ``email``
    # values. All other values are arbitrary.
    #
    # @example
    #   Raven.user_context('id' => 1, 'email' => 'foo@example.com')
    def user_context(options = nil)
      context.user = options || {}
    end

    # Bind tags context. Merges with existing context (if any).
    #
    # Tags are key / value pairs which generally represent things like
    # application version, environment, role, and server names.
    #
    # @example
    #   Raven.tags_context('my_custom_tag' => 'tag_value')
    def tags_context(options = nil)
      context.tags.merge!(options || {})
    end

    # Bind extra context. Merges with existing context (if any).
    #
    # Extra context shows up as Additional Data within Sentry, and is
    # completely arbitrary.
    #
    # @example
    #   Raven.extra_context('my_custom_data' => 'value')
    def extra_context(options = nil)
      context.extra.merge!(options || {})
    end

    def rack_context(env)
      env = nil if env.empty?

      context.rack_env = env
    end

    def breadcrumbs
      BreadcrumbBuffer.current
    end

    private

    def install_at_exit_hook(options)
      at_exit do
        exception = $ERROR_INFO
        if exception
          logger.debug "Caught a post-mortem exception: #{exception.inspect}"
          capture_type(exception, options)
        end
      end
    end
  end
end
