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

  class HTMLGen

    ###############################################################################
    # Navigation, header and footer.
    ###############################################################################

    # Return the HTML for the 'replies' link in the main navigation bar.
    # The link is not shown at all if the user is not logged in, while
    # it is shown with a badge showing the number of replies for logged in
    # users.
    def replies_link
        return "" if !$user
        count = $user['replies'] || 0
        H.a(:href => "/replies", :class => "replies") {
            "replies"+
            if count.to_i > 0
                H.sup {count}
            else "" end
        }
    end

    def application_header
        navitems = [    ["top","/"],
                        ["latest","/latest/0"],
                        ["submit","/submit"]]
        navbar = H.nav {
            navitems.map{|ni|
                H.a(:href=>ni[1]) {H.entities ni[0]}
            }.inject{|a,b| a+"\n"+b}+replies_link
        }
        rnavbar = H.nav(:id => "account") {
            if $user
                H.a(:href => "/user/"+H.urlencode($user['username'])) { 
                    H.entities $user['username']+" (#{$user['karma']})"
                }+
                H.a(:href =>
                    "/logout?apisecret=#{$user['apisecret']}") {
                    "logout"
                }
            else
                H.a(:href => "/login") {"Login"}
            end
        }
        H.header {
          header = H.nav {
            H.a(:href => "/", :class => "icon") { H.img(:src => "/images/favicon_invert.png" ) }
          }
          if $user
            header << navbar
          end
          header << rnavbar
        }
    end

    def application_footer
        if $user
            apisecret = H.script() {
                "var apisecret = '#{$user['apisecret']}';";
            }
        else
            apisecret = ""
        end
        if KeyboardNavigation == 1
            keyboardnavigation = H.script() {
                "setKeyboardNavigation();"
            }
        else
            keyboardnavigation = ""
        end
        footer = H.footer {
            links = [
                ["source code", "http://github.com/artilect/bunkernews"],
                ["rss feed", "/rss"],
                ["twitter", FooterTwitterLink],
                ["google group", FooterGoogleGroupLink]
            ]
            H.nav {
              links.map{ |l| l[1] ? H.a(:href => l[1]) {H.entities l[0]} : nil }.select{ |l| l }.join(" ")
            }
        }+apisecret+keyboardnavigation
        $user ? footer : ""
    end
  end
end