Sometimes, you just want some code to run on only one machine in a cluster
at any particular time.  Perhaps you only need one copy running, and you'd
like to have something ready to failover, or maybe you want to make sure you
don't take down all your machines simultaneously for a code upgrade.

Either way, `Consul::Mutex` has got you covered.


# Installation

It's a gem:

    gem install consul-mutex

There's also the wonders of [the Gemfile](http://bundler.io):

    gem 'consul-mutex'

If you're the sturdy type that likes to run from git:

    rake install

Or, if you've eschewed the convenience of Rubygems entirely, then you
presumably know what to do already.


# Usage

Simply instantiate a new `Consul::Mutex`, giving it the key you want to use
as the "lock":

    require 'consul/mutex'

    mutex = Consul::Mutex.new('/my/something/weird')

Then, whenever you want to only have one thing running at once, run the code
inside a block passed to `#synchronize`:

    mutex.synchronize { print "There can be"; sleep 5; puts " only one." }

If your consul server is not accessable via `http://localhost:8500`, you'll
need to tell `Consul::Mutex` where to find it:

    mutex = Consul::Mutex.new('/some/key', consul_url: 'http://consul:8500')

By default, the "value" of the lock resource will be the hostname of the
machine that it's running on (so you know who has the lock).  If, for some
reason, you'd like to set the value to something else, you can do that, too:

    mutex = Consul::Mutex.new('/some/key', value: "It is now #{Time.now}")


## Failure Is An Option

One thing that is a bit unsettling about Consul-mediated mutexes is that
the lock can be "lost" for a variety of reasons.  The most common one, of
course, is simple communications failure -- if you're on the wrong side of a
split-brain, the rest of the cluster can recover and continue on, and you no
longer have the lock, because your half of the cluster is dead.  Consul also
allows locks to be force-unlocked by an operator, because otherwise, if
something died without unlocking, the lock would be held *forever*.

As a result of all this, the block of code that you pass to `#synchronize`
runs on a separate thread, and *can be killed without warning* if the mutex
determines that it no longer holds the lock.  That means you want to be a
bit extra-careful about idempotence and releasing resources you acquire (via
`ensure` blocks).


# Contributing

Bug reports should be sent to the [Github issue
tracker](https://github.com/mpalmer/consul-mutex/issues), or
[e-mailed](mailto:theshed+consul-mutex@hezmatt.org).  Patches can be sent as a
Github pull request, or [e-mailed](mailto:theshed+consul-mutex@hezmatt.org).


# Licence

Unless otherwise stated, everything in this repo is covered by the following
copyright notice:

    Copyright (C) 2015 Civilized Discourse Construction Kit Inc.
    
    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License version 3, as
    published by the Free Software Foundation.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
