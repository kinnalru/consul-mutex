require 'socket'

module ExampleMethods
	def trace_requests
		WebMock.after_request do |req, res|
			puts '----->8-----'
			puts "#{req.method.to_s.upcase} #{req.uri}"
			puts res.status
			puts (res.headers || {}).map { |k,v| "#{k}: #{v}" }.join("\n")
			puts
			puts res.body
			puts '-----8<-----'
		end
	end

	def json_response(data, extra_headers = {})
		{
			:status  => 200,
			:headers => extra_headers.merge('Content-Type' => 'application/json'),
			:body    => data.to_json,
		}
	end

	def stub_req(verb, url, with = nil)
		@stub_req ||= {}

		req_key = [verb, url, with]

		req = @stub_req[req_key] ||= begin
			req = stub_request(verb, url)
			if with
				req.with(with)
			end
			
			[req, 0]
		end
		
		req[1] += 1
		req[0]
	end

	def verify_requested_stubs
		@stub_req.values.each do |req, count|
			expect(req).to have_been_requested.times(count)
		end
	end

	def handle_common_errors(err, req)
		case err
			when :return_500
				req.to_return(:status => 500)
			when :return_404
				req.to_return do
					sleep 0.02
					{
					  :status => 404,
					  :headers => {
					    'X-Consul-Index' => 42
					  }
					}
				end
			when :timeout
				req.to_timeout
			when :econnrefused
				req.to_raise(Errno::ECONNREFUSED.new("ERR"))
			when :bad_response
				req.to_raise(Net::HTTPBadResponse.new("ERR"))
			when :dns_failure
				req.to_raise(SocketError.new("getaddrinfo: Name or service not known"))
			when :unparseable_json
				req.to_return(
				  :status  => 200,
				  :headers => { 'Content-Type' => 'application/json' },
				  :body    => "this isn't really JSON",
				)
			else
				nil
		end
	end

	def stub_create_session(err = nil)
		req = stub_req(:put, 'localhost:8500/v1/session/create', :body => '')

		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(json_response(:ID => 'xyzzy123'))
				when :no_id
					req.to_return(json_response({}))
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end

	def stub_get_key(err = nil)
		req = stub_req(:get, 'localhost:8500/v1/kv/some/lock?consistent')
		
		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(:status => 404)
				when :exists
					req.to_return(json_response([{:Value => 'omfg'}]))
				when :locked
					req.to_return(
					  json_response(
						 [{
							:Session => 'lolidunno'
						 }],
						 'X-Consul-Index' => '42'
					  )
					)
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end

	def stub_get_key_wait(err = nil)
		req = stub_req(:get, 'localhost:8500/v1/kv/some/lock?consistent&index=42')

		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(:status => 404)
				when :locked
					req.to_return(
					  json_response(
						 [{
							:Session => 'lolidunno'
						 }],
						 'X-Consul-Index' => '42'
					  )
					)
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end

	def stub_acquire_lock(err = nil)
		req = stub_req(
		  :put,
		  'localhost:8500/v1/kv/some/lock?acquire=xyzzy123',
		  :body => Socket.gethostname
		)
		
		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(json_response(true))
				when :fail
					req.to_return(json_response(false))
				when :json_hash
					req.to_return(json_response({:something => 'unexpected'}))
				else
					raise ArgumentError,
					      "Unknown error #{err.inspect}"
			end
		end
	end

	def stub_check_key(err = nil)
		req = stub_req(:get, 'localhost:8500/v1/kv/some/lock?consistent')
		
		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(
					  json_response(
						 [{
							:Value => [Socket.gethostname].pack('m0'),
							:Session => 'xyzzy123',
						 }],
						 'X-Consul-Index' => '42'
					  )
					)
				when :held_by_other
					req.to_return(
					  json_response(
					    [{
					      :Value => 'faff',
					      :Session => 'other',
					    }],
					    'X-Consul-Index' => '42'
					  )
					)
				when :null_session
					req.to_return { json_response([{:Session => nil}]) }
				else
					raise ArgumentError,
					      "Unknown error #{err.inspect}"
			end
		end
	end

	def stub_watch_key(err = nil)
		req = stub_req(:get, 'localhost:8500/v1/kv/some/lock?consistent&index=42')

		if handle_common_errors(err, req).nil?
			case err
				when nil
				  req.to_return { sleep 2; :you_should_never_see_this }
				when :other_session
					req.to_return { sleep 0.02; json_response([{:Session => 'other'}]) }
				when :null_session
					req.to_return { sleep 0.02; json_response([{:Session => nil}]) }
				when :changed
					req.to_return do
						json_response(
						  [{
						    :Session => 'xyzzy123'
						  }],
						  'X-Consul-Index' => '42'
						)
					end
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end

	def stub_release_lock(err = nil)
		req = stub_req(
		  :put,
		  'localhost:8500/v1/kv/some/lock?release=xyzzy123',
		  :body => ''
		)

		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(json_response(true))
				when :false
					req.to_return(json_response(false))
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end

	def stub_del_session(err = nil)
		req = stub_req(:put, 'localhost:8500/v1/session/destroy/xyzzy123')

		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(json_response(true))
				when :false
					req.to_return(json_response(false))
				else
					raise ArgumentError,
					      "Unknown error #{err.inspect}"
			end
		end
	end

	def stub_check_del_key(err = nil)
		req = stub_req(:get, 'localhost:8500/v1/kv/some/lock?consistent')

		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(json_response([{ :Value => nil }], "X-Consul-Index" => "69"))
				when :relocked
					req.to_return(
					  json_response(
					    [{
					      :Value => 'foo',
					      :Session => 'other',
					    }],
					    "X-Consul-Index" => "69"
					  )
					)
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end

	def stub_del_key(err = nil)
		req = stub_req(:delete, 'localhost:8500/v1/kv/some/lock?cas=69')

		if handle_common_errors(err, req).nil?
			case err
				when nil
					req.to_return(json_response(true))
				when :false
					req.to_return(json_response(false))
				else
					raise ArgumentError,
							"Unknown error #{err.inspect}"
			end
		end
	end
end
