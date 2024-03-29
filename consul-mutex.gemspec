begin
	require 'git-version-bump'
rescue LoadError
	nil
end

Gem::Specification.new do |s|
	s.name = "consul-mutex"

	s.version = GVB.version rescue "0.0.0.1.NOGVB"
	s.date    = GVB.date    rescue Time.now.strftime("%Y-%m-%d")

	s.platform = Gem::Platform::RUBY

	s.summary  = "Manage distributed code with a Consul-mediated mutex"

	s.authors  = ["Matt Palmer"]
	s.email    = ["theshed+consul-mutex@hezmatt.org"]
	s.homepage = "http://theshed.hezmatt.org/consul-mutex"

	s.files = `git ls-files -z`.split("\0").reject { |f| f =~ /^(G|spec|Rakefile)/ }

	s.required_ruby_version = ">= 1.9.3"

	s.add_runtime_dependency 'nesty', '~> 1.0'

	s.add_development_dependency 'bundler'
	s.add_development_dependency 'github-release'
	s.add_development_dependency 'guard-spork'
	s.add_development_dependency 'guard-rspec'
	s.add_development_dependency 'rake', '~> 10.4', '>= 10.4.2'
	# Needed for guard
	s.add_development_dependency 'rb-inotify', '~> 0.9'
	s.add_development_dependency 'redcarpet'
	s.add_development_dependency 'rspec'
	s.add_development_dependency 'webmock'
	s.add_development_dependency 'yard'
end
