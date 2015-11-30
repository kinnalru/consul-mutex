require_relative 'spec_helper'
require 'consul/mutex'

describe Consul::Mutex do
	let(:mutex) { Consul::Mutex.new('/some/lock') }

	let(:mutex_mock) { double(Object).tap { |m| allow(m).to receive(:foo) } }
	
	def run_mutex
		mutex.synchronize { sleep 0.03; mutex_mock.foo }
	end

	shared_examples "common failure modes" do |webmock_stub|
		context "due to Consul timing out" do
			it "raises a ConsulError" do
				send(webmock_stub, :timeout)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
		
		context "due to ECONNREFUSED" do
			it "raises a ConsulError" do
				send(webmock_stub, :econnrefused)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
		
		context "due to DNS failure" do
			it "raises a ConsulError" do
				send(webmock_stub, :dns_failure)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
		
		context "due to 500 response" do
			it "raises a ConsulError" do
				send(webmock_stub, :return_500)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end

		context "due to a bad HTTP response" do
			it "raises a ConsulError" do
				send(webmock_stub, :bad_response)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end

		context "due to unparseable JSON" do
			it "raises a ConsulError" do
				send(webmock_stub, :unparseable_json)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
	end

	context "fail to create session" do
		before :each do
			stub_get_key
		end

		include_examples "common failure modes", :stub_create_session

		context "because no ID is returned" do
			it "raises a ConsulError" do
				stub_create_session(:no_id)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
	end

	context "fail initial get key" do
		include_examples "common failure modes", :stub_get_key
	end

	context "GET waiting for lock fails" do
		before :each do
			stub_get_key(:locked)
		end

		include_examples "common failure modes", :stub_get_key_wait
	end

	context "failure on lock acquisition" do
		before :each do
			stub_get_key
			stub_create_session
		end

		include_examples "common failure modes", :stub_acquire_lock
		
		context "due to unexpected JSON value" do
			it "raises a ConsulError" do
				stub_acquire_lock(:json_hash)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
	end

	context "failure on check key after lock acquisition" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
		end

		include_examples "common failure modes", :stub_check_key
	end

	context "failure on key watch" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
			stub_check_key
			stub_release_lock
			stub_del_session
			stub_del_key
		end

		include_examples "common failure modes", :stub_watch_key
	end

	context "failure on key watch and lock release" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
			stub_check_key
			stub_release_lock(:return_500)
		end

		include_examples "common failure modes", :stub_watch_key
	end

	context "failure on lock release" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
			stub_check_key
			stub_watch_key
		end

		include_examples "common failure modes", :stub_release_lock

		context "due to returning false" do
			it "throws an error" do
				stub_release_lock(:false)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
	end

	context "failure on session deletion" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
		end

		include_examples "common failure modes", :stub_del_session

		context "due to returning false" do
			it "throws an error" do
				stub_del_session(:false)
				
				expect { run_mutex }.to raise_error(Consul::Mutex::ConsulError)
			end
		end
	end

	context "failure on key deletion check" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
		end

		include_examples "common failure modes", :stub_check_del_key
	end

	context "failure on key deletion" do
		before :each do
			stub_get_key
			stub_create_session
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
		end

		include_examples "common failure modes", :stub_del_key
	end
end
