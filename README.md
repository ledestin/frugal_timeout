frugal_timeout
==============

[![Build Status](https://travis-ci.org/ledestin/frugal_timeout.png)](https://travis-ci.org/ledestin/frugal_timeout)
Ruby Timeout.timeout replacement using only 2 threads

## Example

```
require 'frugal_timeout'

# Ensure that calling timeout() will use FrugalTimeout.timeout()
FrugalTimeout.dropin!

begin
  timeout(0.1) { sleep }
rescue Timeout::Error
  puts 'yay!'
end

begin
  timeout(0.1) { sleep }
rescue FrugalTimeout::Error
  puts 'yay again!'
end
```
