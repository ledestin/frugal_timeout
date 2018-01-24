frugal_timeout
==============

[![Build Status](https://travis-ci.org/ledestin/frugal_timeout.png)](https://travis-ci.org/ledestin/frugal_timeout)
[![Coverage Status](https://coveralls.io/repos/github/ledestin/frugal_timeout/badge.svg?branch=master)](https://coveralls.io/github/ledestin/frugal_timeout?branch=master)
[![Code Climate](https://codeclimate.com/github/ledestin/frugal_timeout.png)](https://codeclimate.com/github/ledestin/frugal_timeout)

Ruby Timeout.timeout replacement using only 1 thread

## Why

As you may know, the stock Timeout.timeout uses thread per timeout call. If you
use it a lot, you will soon be out of threads. This gem is to provide an
alternative that uses only 1 thread.

Also, there's a race condition in the 1.9-2.0 stock timeout. Consider the
following code:
```ruby
timeout(0.02) {
  timeout(0.01, IOError) { sleep }
}
```

In this case, the stock timeout will most likely raise IOError, but, given the
race condition, sometimes it can also raise Timeout::Error. Just put `sleep 0.1'
inside stock timeout ensure to trigger that. As of version 0.0.9, frugal_timeout
will always raise IOError.

## Example

```ruby
require 'frugal_timeout'

begin
  FrugalTimeout.timeout(0.1) { sleep }
rescue Timeout::Error
  puts 'it works!'
end

# Ensure that calling timeout() will use FrugalTimeout.timeout().
FrugalTimeout.dropin!

# Rescue frugal-specific exception if needed.
begin
  timeout(0.1) { sleep }
rescue FrugalTimeout::Error
  puts 'yay!'
end
```

## Installation

Tested on Ruby 1.9.3 and 2.0.0.

```
gem install frugal_timeout
```
