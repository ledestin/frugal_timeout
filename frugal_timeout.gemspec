Gem::Specification.new do |s|
  s.name        = 'frugal_timeout'
  s.version     = '0.0.7'
  s.date        = '2013-10-20'
  s.summary     = 'Timeout.timeout replacement'
  s.description = 'Timeout.timeout replacement that uses only 2 threads'
  s.authors     = ['Dmitry Maksyoma']
  s.email       = 'ledestin@gmail.com'
  s.files       = ['lib/frugal_timeout.rb']
  s.require_paths = ['lib']
  s.homepage    = 'https://github.com/ledestin/frugal_timeout'

  s.add_development_dependency 'rspec', '>= 2.13'
  s.add_runtime_dependency 'hitimes', '~> 1.2'
end
