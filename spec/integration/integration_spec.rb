require 'spec_helper'

RSpec.describe 'integration test', skip: (!ENV['SLACK_API_TOKEN'] || !ENV['CONCURRENCY']) && 'missing SLACK_API_TOKEN and/or CONCURRENCY' do
  around do |ex|
    WebMock.allow_net_connect!
    VCR.turned_off { ex.run }
    WebMock.disable_net_connect!
  end

  let(:logger) do
    logger = Logger.new(STDOUT)
    logger.level = Logger::INFO
    logger
  end

  before do
    Thread.abort_on_exception = true

    Slack.configure do |slack|
      slack.logger = logger
    end

    @queue = QueueWithTimeout.new
  end

  after do
    Slack.config.reset
  end

  let(:client) { Slack::RealTime::Client.new(token: ENV['SLACK_API_TOKEN']) }

  let(:queue) { @queue }

  def start
    # starts the client and pushes an item on a queue when connected
    client.start_async do |driver|
      driver.on :open do |data|
        logger.debug "connection.on :open, data=#{data}"
        queue.push nil
      end
    end
  end

  before do
    client.on :hello do
      logger.info "Successfully connected, welcome '#{client.self.name}' to the '#{client.team.name}' team at https://#{client.team.domain}.slack.com."
    end

    client.on :close do
      logger.info 'Disconnecting ...'
      # pushes another item to the queue when disconnected
      queue.push nil if @queue
    end
  end

  def start_server
    dt = rand(5) + 2
    logger.debug "#start_server, waiting #{dt} second(s)"
    sleep dt # prevent Slack 429 rate limit errors
    # start server and wait for on :open
    @server = start
    logger.debug "started #{@server}"
    queue.pop_with_timeout(5)
  end

  def wait_for_server
    return unless @queue

    logger.debug '#wait_for_server'
    queue.pop_with_timeout(5)
    logger.debug '#wait_for_server, joined'
    @queue = nil
  end

  def stop_server
    logger.debug '#stop_server'
    client.stop!
    logger.debug '#stop_server, stopped'
  end

  after do
    wait_for_server
    @server.join if @server.is_a?(::Thread)
  end

  context 'client connected' do
    before do
      start_server
    end

    let(:channel) { "@#{client.self.id}" }

    it 'responds to message' do
      message = SecureRandom.hex

      client.on :message do |data|
        logger.debug data
        # concurrent execution of tests causes messages to arrive in any order
        next unless data.text == message

        expect(data.text).to eq message
        expect(data.subtype).to eq 'bot_message'
        logger.debug 'client.stop!'
        expect(client.started?).to be true
        client.stop!
      end

      logger.debug "chat_postMessage, channel=#{channel}, message=#{message}"
      client.web_client.chat_postMessage channel: channel, text: message
    end

    it 'sends message' do
      client.message(channel: channel, text: 'Hello world!')
      client.stop!
    end
  end

  it 'gets hello' do
    client.on :hello do |data|
      logger.debug "client.on :hello, data=#{data}"
      expect(client.started?).to be true
      client.stop!
    end

    start_server
  end

  context 'with websocket_ping set' do
    before do
      client.websocket_ping = 2
    end
    it 'sends pings' do
      @reply_to = nil
      client.on :pong do |data|
        @reply_to = data.reply_to
        client.stop!
      end
      start_server
      queue.pop_with_timeout(5)
      expect(@reply_to).to be 1
    end
    it 'no longer sends pings when #disconnect! is called' do
      @reply_to = nil
      client.on :pong do |data|
        @reply_to = data.reply_to
        client.stop! if data.reply_to == 2
      end
      start_server
      queue.pop_with_timeout(10)
      expect(@reply_to).to be 2
    end
  end

  context 'with websocket_ping not set' do
    before do
      client.websocket_ping = 0
    end
    it 'does not send pings' do
      @reply_to = nil
      client.on :pong do |data|
        @reply_to = data.reply_to
      end
      client.on :hello do
        client.stop!
      end
      start_server
      wait_for_server
      expect(@reply_to).to be nil
    end
  end

  it 'gets close, followed by closed' do
    client.on :hello do
      expect(client.started?).to be true
      client.stop!
    end

    client.on :close do |data|
      logger.debug "client.on :close, data=#{data}"
      @close_called = true
    end

    client.on :closed do |data|
      logger.debug "client.on :closed, data=#{data}"
      expect(@close_called).to be true
    end

    start_server
  end
end
