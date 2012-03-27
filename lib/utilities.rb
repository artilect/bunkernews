# Copyright 2011 Salvatore Sanfilippo. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY SALVATORE SANFILIPPO ''AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
# NO EVENT SHALL SALVATORE SANFILIPPO OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Salvatore Sanfilippo.

class BunkerNews < Sinatra::Application

    ###############################################################################
    # Utility functions
    ###############################################################################

    # Given an unix time in the past returns a string stating how much time
    # has elapsed from the specified time, in the form "2 hours ago".
    def str_elapsed(t)
        seconds = Time.now.to_i - t
        return "now" if seconds <= 1
        return "#{seconds} seconds ago" if seconds < 60
        return "#{seconds/60} minutes ago" if seconds < 60*60
        return "#{seconds/60/60} hours ago" if seconds < 60*60*24
        return "#{seconds/60/60/24} days ago"
    end

    # Generic API limiting function
    def rate_limit_by_ip(delay,*tags)
        key = "limit:"+tags.join(".")
        return true if $r.exists(key)
        $r.setex(key,delay,1)
        return false
    end

    # Show list of items with show-more style pagination.
    #
    # The function sole argument is an hash with the following fields:
    #
    # :get     A function accepinng start/count that will return two values:
    #          1) A list of elements to paginate.
    #          2) The total amount of items of this type.
    #
    # :render  A function that given an element obtained with :get will turn
    #          in into a suitable representation (usually HTML).
    #
    # :start   The current start (probably obtained from URL).
    #
    # :perpage Number of items to show per page.
    #
    # :link    A string that is used to obtain the url of the [more] link
    #          replacing '$' with the right value for the next page.
    #
    # Return value: the current page rendering.
    def list_items(o)
        aux = ""
        o[:start] = 0 if o[:start] < 0
        items,count = o[:get].call(o[:start],o[:perpage])
        items.each{|n|
            aux << o[:render].call(n)
        }
        last_displayed = o[:start]+o[:perpage]
        if last_displayed < count
            nextpage = o[:link].sub("$",
                       (o[:start]+o[:perpage]).to_s)
            aux << H.a(:href => nextpage,:class=> "more") {"[more]"}
        end
        aux
    end

end