module HTTParty
  module HTTPCache
    class NoResponseError < StandardError; end

    mattr_accessor  :perform_caching,
                    :apis,
                    :logger,
                    :redis,
                    :timeout_length,
                    :cache_stale_backup_time,
                    :exception_callback,
                    :read_from_cache,
                    :backups_enabled

    self.perform_caching = false
    self.apis = {}
    self.timeout_length = 5 # 5 seconds
    self.cache_stale_backup_time = 300 # 5 minutes
    self.read_from_cache = true
    self.backups_enabled = true

    def self.reading_from_cache(read_from_cache=true)
      existing_value = self.read_from_cache

      self.read_from_cache = read_from_cache
      yield
    ensure
      self.read_from_cache = existing_value
    end

    def perform
      if cacheable?
        if response_in_cache?
          log_message("Retrieving response from cache")
          response_from(response_body_from_cache)
        else
          validate
          begin
            httparty_response = timeout(timeout_length) do
              super
            end
            httparty_response.parsed_response
            if httparty_response.response.is_a?(Net::HTTPSuccess)
              log_message("Storing good response in cache")
              store_in_cache(httparty_response.body)
              store_backup(httparty_response.body) if HTTPCache.backups_enabled
              httparty_response
            else
              retrieve_and_store_backup(httparty_response)
            end
          rescue *exceptions => e
            raise e unless HTTPCache.backups_enabled

            if exception_callback && exception_callback.respond_to?(:call)
              exception_callback.call(e, redis_key_name, normalized_uri)
            end
            retrieve_and_store_backup
          end
        end
      else
        log_message("Caching off")
        super
      end
    end

    protected

    def cacheable?
      HTTPCache.perform_caching &&
        HTTPCache.apis.keys.include?(uri.host) &&
        http_method == Net::HTTP::Get
    end

    def response_from(response_body)
      HTTParty::Response.new(self, OpenStruct.new(:body => response_body), lambda {parse_response(response_body)})
    end

    def retrieve_and_store_backup(httparty_response = nil)
      if backup_exists?
        log_message('using backup')
        response_body = backup_response
        store_in_cache(response_body, cache_stale_backup_time)
        response_from(response_body)
      elsif httparty_response
        httparty_response
      else
        log_message('No backup and bad response')
        raise NoResponseError, 'Bad response from API server or timeout occured and no backup was in the cache'
      end
    end

    def normalized_uri
      return @normalized_uri if @normalized_uri
      normalized_uri = uri.dup
      normalized_uri.query = sort_query_params(normalized_uri.query)
      normalized_uri.path.chop! if (normalized_uri.path =~ /\/$/)
      normalized_uri.scheme = normalized_uri.scheme.downcase
      @normalized_uri = normalized_uri.normalize.to_s
    end

    def sort_query_params(query)
      query.split('&').sort.join('&') unless query.blank?
    end

    def cache_key_name
      @cache_key_name ||= "api-cache:#{redis_key_name}:#{uri_hash}"
    end

    def uri_hash
      @uri_hash ||= Digest::MD5.hexdigest(normalized_uri)
    end

    def response_in_cache?
      return false unless HTTPCache.read_from_cache
      redis.exists(cache_key_name)
    end

    def backup_key
      "api-cache:#{redis_key_name}"
    end

    def backup_response
      redis.hget(backup_key, uri_hash)
    end

    def backup_exists?
      return false unless HTTPCache.backups_enabled
      redis.hexists(backup_key, uri_hash)
    end

    def response_body_from_cache
      redis.get(cache_key_name)
    end

    def store_in_cache(response_body, expires = nil)
      redis.set(cache_key_name, response_body)
      redis.expire(cache_key_name, (expires || HTTPCache.apis[uri.host][:expire_in]))
    end

    def store_backup(response_body)
      redis.hset(backup_key, uri_hash, response_body)
    end

    def redis_key_name
      HTTPCache.apis[uri.host][:key_name]
    end

    def log_message(message)
      logger.info("[HTTPCache]: #{message} for #{normalized_uri} - #{uri_hash.inspect}") if logger
    end

    def timeout(seconds, &block)
      if defined?(SystemTimer)
        SystemTimer.timeout_after(seconds, &block)
      else
        options[:timeout] = seconds
        yield
      end
    end

    def exceptions
      if (RUBY_VERSION.split('.')[1].to_i >= 9) && defined?(Psych::SyntaxError)
        [StandardError, Timeout::Error, Psych::SyntaxError]
      else
        [StandardError, Timeout::Error]
      end
    end
  end
end
