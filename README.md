frugal_timeout
==============

[![Build Status](https://travis-ci.org/ledestin/frugal_timeout.png)](https://travis-ci.org/ledestin/frugal_timeout)
[![Code Climate](https://codeclimate.com/github/ledestin/frugal_timeout.png)](https://codeclimate.com/github/ledestin/frugal_timeout)
Ruby Timeout.timeout replacement using only 2 threads

## Why

As you may know, the stock Timeout.timeout uses thread per timeout call. If you
use it a lot, you will soon be out of threads. This gem is to provide an
alternative that uses only 2 threads.

## Example

```
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
