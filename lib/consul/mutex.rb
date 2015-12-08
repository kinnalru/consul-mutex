require 'json'
require 'socket'
require 'uri'
require 'thwait'
require 'net/http'
require 'nesty'

if !Kernel.const_defined?(:Consul)
	#:nodoc:
	module Consul; end
end

# A Consul-mediated distributed mutex
#
# Sometimes, you just want some code to run on only one machine in a cluster
# at any particular time.  Perhaps you only need one copy running, and you'd
# like to have something ready to failover, or maybe you want to make sure
# you don't take down all your machines simultaneously for a code upgrade.
#
# Either way, `Consul::Mutex` has got you covered.
#
class Consul::Mutex
	# Indicates something went wrong in the worker thread.
	#
	# Catch this exception if you specifically want to know that your worker
	# thread lost its mind and errored out.  The *actual* exception which
	# caused the thread to terminate is available in `#nested`.
	#
	ThreadExceptionError = Class.new(Nesty::NestedStandardError)

	# Indicates some sort of problem communicating with Consul.
	#
	# Something has gone terribly, terribly wrong, and I need to tell you all
	# about it.
	#
	ConsulError          = Class.new(RuntimeError)

	# Indicates that the worker thread was terminated because we lost the
	# distributed lock.
	#
	# You can't assume *anything* about what state anything is in that you
	# haven't explicitly made true using `ensure`.  In general, if you're
	# getting this exception, something is doing terrible, terrible things to
	# your Consul cluster.
	#
	LostLockError        = Class.new(RuntimeError)

	# Internal-only class to abstract out the details of a Consul KV key,
	# parsing it from the HTTP response into something a little easier
	# to deal with.
	#
	class Key
		attr_reader :consul_index, :session, :value

		def initialize(http_response)
			begin
				json = JSON.parse(http_response.body)
			rescue JSON::ParserError => ex
				raise ConsulError,
				      "Consul returned unparseable JSON: #{ex.message}"
			end

			unless json.is_a?(Array)
				raise ConsulError,
				      "Consul did not return an array; instead, it is a #{json.class}"
			end

			if json.length != 1
				raise ConsulError,
				      "Invalid number of objects returned: expected 1, got #{json.length}"
			end

			json = json.first

			@consul_index = http_response['X-Consul-Index']
			@session      = json['Session']
			@value        = json['Value'].nil? ? nil : json['Value'].unpack("m").first
			
			@last_cas_index = nil
		end
	end
	private_constant :Key

	# Create a new Consul-mediated distributed mutex.
	#
	# @param key [String] the path (within the Consul KV store namespace,
	#   `/v1/kv`) which will be used as the lock key for all operations on
	#   this mutex.  Every mutex created with the same key will exclude with
	#   all other mutexes created with the same key.
	#
	# @option opts [String] :value (hostname) the value to set on the lock
	#   key when we acquire the lock.  This can be anything you like, but
	#   generally you'll want to set something that uniquely identifies who
	#   is currently holding the lock.  The default, the local system's
	#   hostname, is generally a good choice.
	#
	# @option opts [String] :consul_url ('http://localhost:8500') where to
	#   connect to in order to talk to your local Consul cluster.
	#
	def initialize(key, opts = {})
		@key        = key
		@value      = opts.fetch(:value, Socket.gethostname)
		@consul_url = URI(opts.fetch(:consul_url, 'http://localhost:8500'))
	end

	# Run code under the protection of this mutex.
	#
	# This method works similarly to the `Mutex#synchronize` method in the
	# Ruby stdlib.  You pass it a block, and only one instance of the code
	# in the block will be running at any given moment.
	#
	# The big difference is that the blocks of code being mutually excluded
	# can be running in separate processes, on separate machines.  We are
	# truly living in the future.
	#
	# The slightly smaller difference is that the block of code you specify
	# *may* not actually run, or it might be killed whilst running.  You'll
	# always get an exception raised if that occurs, but you'll need to
	# be careful to clean up any state that your code sets using `ensure`
	# blocks (or equivalent).
	#
	# Your block of code is also run on a separate thread within the
	# interpreter from the one in which `#synchronize` itself is called (in
	# case that's important to you).
	#
	# @yield your code will be run once we have acquired the lock which
	#   controls this mutex.
	#
	# @raise [ArgumentError] if no block is passed to this method.
	#
	# @raise [RuntimeError] if some sort of internal logic error occurs
	#   (always a bug in this code, please report)
	#
	# @raise [SocketError] if a mysterious socket-related error occurs.
	#
	# @raise [ConsulError] if an error occurs talking to Consul.  This is
	#   indicative of a problem with the Consul agent, or the network.
	#
	# @raise [ThreadExceptionError] if the worker thread exits with an
	#   exception during execution.  This is indicative of a problem in your
	#   code.
	#
	# @raise [LostLockError] if the Consul lock is somehow disrupted while
	#   the worker thread is running.  This should only happen if the Consul
	#   cluster has a serious problem of some sort, or someone fiddles with
	#   the lock key behind our backs.  Find who is fiddling with the key, and
	#   break their fingers.
	#
	def synchronize
		unless block_given?
			raise ArgumentError,
			      "No block passed to #{self.inspect}#synchronize"
		end

		acquire_lock
		
		begin
			worker_thread  = Thread.new { yield }
			watcher_thread = Thread.new { hold_lock }

			tw = ThreadsWait.new(worker_thread, watcher_thread)
			finished_thread = tw.next_wait

			err = nil

			case finished_thread
				when worker_thread
					# Work completed successfully... excellent
					return worker_thread.value

				when watcher_thread
					# We lost the lock... fiddlesticks
					
					# May as well delete our session now, it's useless
					delete_session

					k = watcher_thread.value
					
					msg = if k.nil?
						"Lost lock, key deleted!"
					else
						if k.session.nil?
							"Lost lock, no active session!"
						else
							"Lost lock to session '#{k.session}'"
						end
					end

					raise LostLockError, msg
				else
					raise RuntimeError,
					      "Mysterious return value from `ThreadsWait#next_wait: #{finished_thread.inspect}"
			end
		ensure
			watcher_thread.kill
			worker_thread.kill

			begin
				worker_thread.join
			rescue Exception => ex
				worker_thread = ex
			end

			begin
				watcher_thread.join
			rescue Exception => ex
				watcher_thread = ex
			end

			release_lock if @session_id

			if worker_thread.is_a?(Exception)
				raise ThreadExceptionError.new(
				        "Worker thread raised exception",
				        worker_thread
				      )
			end
			
			if watcher_thread.is_a?(Exception)
				if watcher_thread.is_a?(ConsulError)
					raise watcher_thread
				else
					raise RuntimeError,
					      "Watcher thread raised exception: " +
					      "#{watcher_thread.message} " +
					      "(#{watcher_thread.class})"
				end
			end
		end
	end

	private
	
	def acquire_lock
		wait_for_free_lock
		
		k = nil
		
		while k.nil? or k.session.nil?
			unless set_key(@value, :acquire => session_id)
				return acquire_lock
			end
			
			# It may seem extremely weird to do this loop construct, *and*
			# get the key immediately after we've just (seemingly) successfully
			# acquired the lock on the key, but here's the thing: consul locks
			# are entirely advisory.  We can get the lock, then someone else
			# can delete the key and recreate it, and our lock on the key is
			# gone.
			#
			# We can guard against someone doing that without our knowledge by
			# requesting the key and waiting for changes (as we will do, in
			# `hold_lock`), but we can only do that once we have a value for
			# `X-Consul-Index` which corresponds to a version of the key which
			# shows that we do, indeed, hold the lock.  Since PUTs on keys
			# don't return `X-Consul-Index`, we need to make a separate GET
			# request in order to get a value for `X-Consul-Index` **and check
			# that response shows we still hold the lock** before we can do
			# our wait-for-change dance in `hold_lock`.
			#
			# Yeah, distributed systems are *fun*, ain't they?
			#
			k = get_key
		end

		if k and k.session != session_id
			# Someone else managed to get the lock out from underneath us.
			# Do the whole dance again.
			acquire_lock
		end
	end

	def wait_for_free_lock
		if (k = get_key(!@last_cas_index.nil?)).nil? or k.session.nil?
			# The wait... is over!
			return
		else
			wait_for_free_lock
		end
	end
	
	def get_key(on_change = false)
		url = key_url.dup

		if on_change and @last_cas_index.nil?
			raise RuntimeError,
			      "on_change=true and @last_cas_index.nil? -- that shouldn't happen, file a bug"
		end

		query_args = if on_change and @last_cas_index
			{ :index => @last_cas_index }
		else
			{}
		end
		
		url.query = URI.encode_www_form({ :consistent => nil }.merge(query_args))

		consul_connection do |http|
			res = http.get(url.request_uri)

			case res.code
				when '404'
					nil
				when '200'
					Key.new(res).tap { |k| @last_cas_index = k.consul_index }
				else
					raise ConsulError,
				      "Consul returned bad response to GET #{url.request_uri}: #{res.code}: #{res.message}"
			end
		end
	end

	def set_key(value, query_args = {})
		url = key_url.dup
		url.query = URI.encode_www_form(query_args)

		consul_connection do |http|
			res = http.request(Net::HTTP::Put.new(url.request_uri), value)
			
			if res.code == '200'
				case res.body
					when 'true'
						return true
					when 'false'
						return false
					else
						raise ConsulError,
						      "Unexpected response body to PUT #{url.request_uri}: #{res.body.inspect}"
				end
			else
				raise ConsulError,
				      "Unexpected response code to PUT #{url.request_uri}: #{res.code} #{res.message}"
			end
		end
	end

	def delete_key(query_args)
		url = key_url.dup
		url.query = URI.encode_www_form(query_args)
		
		consul_connection do |http|
			res = http.request(Net::HTTP::Delete.new(url.request_uri))
			
			if res.code != '200'
				raise ConsulError,
				      "Unexpected Consul response to DELETE #{url.request_uri}: #{res.code} #{res.message}"
			elsif res.body != 'true' and res.body != 'false'
				raise ConsulError,
				      "Unexpected Consul response to DELETE #{url.request_uri}: #{res.body}"
			end
		end
	end
	
	def hold_lock
		loop do
			k = get_key(true)

			if k.nil? or k.session.nil? or k.session != session_id
				return k
			end
		end
	end
	
	def release_lock
		unless set_key('', :release => session_id)
			raise ConsulError,
			      "Attempt to release lock returned false"
		end

		delete_session
		k = get_key
		delete_key(:cas => k.consul_index) if k and k.session.nil?
	end

	def key_url
		@key_url ||= sub_url('/v1/kv/' + @key)
	end
	
	def sub_url(path)
		@consul_url.dup.tap do |url|
			url.path += '/' + path
			url.path.gsub!('//', '/')
		end
	end

	def consul_connection
		begin
			Net::HTTP.start(
			  @consul_url.host,
			  @consul_url.port,
			  :use_ssl      => @consul_url.scheme == 'https',
			  :read_timeout => 86400,
			  :ssl_timeout  => 86400
			) do |http|
				yield http
			end
		rescue Timeout::Error
			raise ConsulError,
					"Consul request failed: timeout"
		rescue Errno::ECONNREFUSED
			raise ConsulError,
					"Consul request failed: connection refused"
		rescue SocketError => ex
			if ex.message == 'getaddrinfo: Name or service not known'
				raise ConsulError,
						"Consul request failed: Name resolution failure"
			else
				raise
			end
		rescue Net::HTTPBadResponse => ex
			raise ConsulError,
			      "Bad HTTP response from Consul: #{ex.message}"
		end
	end

	def session_id
		@session_id ||= begin
			consul_connection do |http|
				res = http.request(Net::HTTP::Put.new(sub_url('/v1/session/create'), {}))
				
				id = if res.code == '200'
					begin
						JSON.parse(res.body)['ID']
					rescue JSON::ParserError => ex
						raise ConsulError,
						      "Unparseable response from Consul session create: #{ex.message}"
					end
				else
					raise ConsulError,
					      "Unexpected response from Consul session creation: #{res.code} #{res.message}"
				end
				
				if id.nil?
					raise ConsulError,
					      "Consul did not provide us a session ID"
				end
				
				id
			end
		end
	end

	def delete_session
		consul_connection do |http|
			res = http.request(Net::HTTP::Put.new(sub_url("/v1/session/destroy/#{@session_id}"), {}))
			
			if res.code != '200'
				raise ConsulError,
				      "Unexpected Consul response to session deletion: #{res.code} #{res.message}"
			elsif res.body != 'true'
				raise ConsulError,
				      "Unexpected Consul response to session deletion: #{res.body}"
			else
				@session_id = nil
			end
		end
	end
end
