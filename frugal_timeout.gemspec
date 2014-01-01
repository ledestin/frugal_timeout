Gem::Specification.new do |s|
  s.name        = 'frugal_timeout'
  s.version     = '0.0.10'
  s.date        = '2014-01-02'
  s.summary     = 'Timeout.timeout replacement'
  s.description = 'Timeout.timeout replacement that uses only 1 thread'
  s.authors     = ['Dmitry Maksyoma']
  s.email       = 'ledestin@gmail.com'
  s.files       = `git ls-files`.split($\)
  s.test_files = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ['lib']
  s.homepage    = 'https://github.com/ledestin/frugal_timeout'

  s.add_development_dependency 'rspec', '>= 2.13'
  s.add_runtime_dependency 'hitimes', '~> 1.2'
end
