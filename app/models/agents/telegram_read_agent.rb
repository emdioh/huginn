require 'httmultiparty'
require 'open-uri'
require 'tempfile'

module Agents
  class TelegramReadAgent < Agent
    include FormConfigurable

    cannot_receive_events!

    description <<-MD
      The Telegram Agent reads telegram messages from a [Telegram](https://telegram.org/) bot and sends them out as events.

      **Setup**

      * Obtain an `auth_token` by [creating a new bot](https://telegram.me/botfather).
      * If you would like to send messages to a public channel:
        * Add your bot to the channel as an administrator
      * If you would like to send messages to a group:
        * Add the bot to the group
      * If you would like to send messages privately to yourself:
        * Open a conservation with the bot by visiting https://telegram.me/YourHuginnBot
      * Send a message to the bot, group or channel.

      See the official [Telegram Bot API documentation](https://core.telegram.org/bots/api#available-methods) for detailed info.
    MD

    def default_options
      {
        auth_token: 'xxxxxxxxx:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
        # chat_id: 'xxxxxxxx'
      }
    end

    form_configurable :auth_token, roles: :validatable

    def validate_auth_token
      HTTMultiParty.post(telegram_bot_uri('getMe'))['ok']
    end

    def validate_options
      errors.add(:base, 'auth_token is required') unless options['auth_token'].present?
    end

    def working?
      received_event_without_error? && !recent_error_logs?
    end

    def receive(incoming_events)
      incoming_events.each do |event|
        receive_event event
      end
    end

    private

    TELEGRAM_ACTIONS = {
      text:     :sendMessage,
      photo:    :sendPhoto,
      audio:    :sendAudio,
      document: :sendDocument,
      video:    :sendVideo
    }.freeze

    def configure_params(params)
      params[:chat_id] = interpolated['chat_id']
      params
    end

    def load_field(event, field)
      payload = event.payload[field]
      return false unless payload.present?
      return payload if field == :text
      load_file payload
    end

    def load_file(url)
      file = Tempfile.new [File.basename(url), File.extname(url)]
      file.binmode
      file.write open(url).read
      file.rewind
      file
    end

    def check
      response = HTTMultiParty.post telegram_bot_uri("getUpdates")
    end

    def receive_event(event)
      interpolate_with event do
        messages_send = TELEGRAM_ACTIONS.count do |field, _method|
          payload = load_field event, field
          next unless payload
          send_telegram_messages field, configure_params(field => payload)
          unlink_file payload if payload.is_a? Tempfile
          true
        end
        error("No valid key found in event #{event.payload.inspect}") if messages_send.zero?
      end
    end

    def send_message(field, params)
      response = HTTMultiParty.post telegram_bot_uri(TELEGRAM_ACTIONS[field]), query: params
      unless response['ok']
        error(response)
      end
    end

    def send_telegram_messages(field, params)
      if interpolated['long_message'] == 'split'
        if field == :text
          params[:text].scan(/\G(?:\w{4096}|.{1,4096}(?=\b|\z))/m) do |message|
            send_message field, configure_params(field => message.strip) unless message.strip.blank?
          end
        else
          caption_array = params[:caption].scan(/\G(?:\w{200}|.{1,200}(?=\b|\z))/m)
          params[:caption] = caption_array.first.strip
          send_message field, params
          caption_array.drop(1).each do |caption|
            send_message(:text, configure_params(text: caption.strip)) unless caption.strip.blank?
            end
        end
      else
        params[:caption] = params[:caption][0..199] if params[:caption]
        params[:text] = params[:text][0..4095] if params[:text]
        send_message field, params
      end
    end

    def telegram_bot_uri(method)
      "https://api.telegram.org/bot#{interpolated['auth_token']}/#{method}"
    end

    def unlink_file(file)
      file.close
      file.unlink
    end

    def update_to_complete(update)
      chat = (update['message'] || update.fetch('channel_post', {})).fetch('chat', {})
      {id: chat['id'], text: chat['title'] || "#{chat['first_name']} #{chat['last_name']}"}
    end
  end
end
