require_relative './spec_helper'
require 'consul/mutex'

describe Consul::Mutex do
	let(:mutex) { Consul::Mutex.new('/some/lock') }

	let(:mutex_mock) { double(Object).tap { |m| allow(m).to receive(:foo) } }
	
	def run_mutex
		mutex.synchronize { sleep 0.05; mutex_mock.foo }
	end

	context "straight-through run" do
		it "makes all the right requests" do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "lock key already exists" do
		it "completes successfully" do
			stub_create_session
			stub_get_key(:exists)
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "already locked" do
		it "waits until the lock is available" do
			stub_create_session
			stub_get_key(:locked)
			4.times { stub_get_key_wait(:locked) }
			stub_get_key_wait
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "acquire doesn't work straight away" do
		it "retries" do
			stub_create_session
			stub_get_key
			stub_acquire_lock(:fail)
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "acquire fails repeatedly" do
		it "retries until the lock is available" do
			stub_create_session
			stub_get_key
			12.times { stub_acquire_lock(:fail); stub_get_key }
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end

	end

	context "check key shows lock held by someone else" do
		it "makes all the right requests" do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key(:held_by_other)
			stub_get_key_wait
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "check key returns 404" do
		it "makes all the right requests" do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key(:return_404)
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "check key returns null session" do
		it "makes all the right requests" do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key(:null_session)
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "lock needs to be re-held" do
		it "makes all the right requests" do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			7.times { stub_watch_key(:changed) }
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key

			expect(mutex_mock).to receive(:foo)

			run_mutex

			verify_requested_stubs
		end
	end

	context "worker code fails" do
		before :each do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key
		end

		it "raises a nested exception" do
			expect do
				mutex.synchronize { sleep 0.01; raise Errno::EEXIST }
			end.to raise_error(Consul::Mutex::ThreadExceptionError) do |ex|
				ex.nested.class == Errno::EEXIST
			end
		end
			
		it "releases the lock" do
			mutex.synchronize { sleep 0.01; raise Errno::EEXIST } rescue nil

			verify_requested_stubs
		end
	end
	
	context "lock is lost to another session" do
		before :each do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key(:other_session)
			stub_del_session
		end

		it "raises an exception" do
			expect do
				mutex.synchronize { sleep 5 }
			end.to raise_error(Consul::Mutex::LostLockError, "Lost lock to session 'other'")
		end

		it "kills the worker thread" do
			expect(mutex_mock).to receive(:foo)
			expect(mutex_mock).to_not receive(:bar)

			mutex.synchronize { mutex_mock.foo; sleep 5; mutex_mock.bar } rescue nil
		end

		it "cleans up the session" do
			mutex.synchronize { sleep 5 } rescue nil
			
			verify_requested_stubs
		end

		it "doesn't delete the key" do
			mutex.synchronize { sleep 5 } rescue nil
			
			expect(WebMock).not_to have_requested(:delete, 'localhost:8500/v1/kv/some/lock')
		end
	end

	context "lock session becomes null" do
		before :each do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key(:null_session)
			stub_del_session
		end

		it "raises an exception" do
			expect do
				mutex.synchronize { sleep 5 }
			end.to raise_error(Consul::Mutex::LostLockError, "Lost lock, no active session!")
		end

		it "kills the worker thread" do
			expect(mutex_mock).to receive(:foo)
			expect(mutex_mock).to_not receive(:bar)

			mutex.synchronize { mutex_mock.foo; sleep 5; mutex_mock.bar } rescue nil
		end

		it "session is cleaned up" do
			mutex.synchronize { sleep 5 } rescue nil
			
			verify_requested_stubs
		end

		it "doesn't delete the key" do
			mutex.synchronize { sleep 5 } rescue nil
			
			expect(WebMock).not_to have_requested(:delete, 'localhost:8500/v1/kv/some/lock')
		end
	end

	context "lock key is deleted" do
		before :each do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key(:return_404)
			stub_del_session
		end

		it "raises an exception" do
			expect do
				mutex.synchronize { sleep 5 }
			end.to raise_error(Consul::Mutex::LostLockError, "Lost lock, key deleted!")
		end

		it "kills the worker thread" do
			expect(mutex_mock).to receive(:foo)
			expect(mutex_mock).to_not receive(:bar)

			mutex.synchronize { mutex_mock.foo; sleep 5; mutex_mock.bar } rescue nil
		end

		it "session is cleaned up" do
			mutex.synchronize { sleep 5 } rescue nil
			
			verify_requested_stubs
		end
	end

	context "lock is already re-locked before deletion" do
		before :each do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key(:relocked)
		end
		
		it "runs successfully" do
			run_mutex
			
			verify_requested_stubs
		end
		
		it "doesn't delete the key" do
			mutex.synchronize { sleep 0.05 } rescue nil
			
			expect(WebMock).not_to have_requested(:delete, 'localhost:8500/v1/kv/some/lock')
		end
	end

	context "lock key deletion soft-fails" do
		before :each do
			stub_create_session
			stub_get_key
			stub_acquire_lock
			stub_check_key
			stub_watch_key
			stub_release_lock
			stub_del_session
			stub_check_del_key
			stub_del_key(:false)
		end
		
		it "runs successfully" do
			run_mutex
			
			verify_requested_stubs
		end
	end
end
