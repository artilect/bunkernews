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

require './config'

require './lib/pbkdf2'
#require 'openssl' if UseOpenSSL
require './lib/html_gen'
require './lib/redis_comments'

require './lib/routes'
require './lib/api'
require './lib/navigation'
require './lib/auth'
require './lib/news'
require './lib/comments'
require './lib/utilities'


Version = "0.0.1"

class BunkerNews < Sinatra::Application

  before do
      $r = Redis.new(:host => RedisHost, :port => RedisPort) if !$r
      H = HTMLGen.new if !defined?(H)
      if !defined?(Comments)
          Comments = RedisComments.new($r,"comment",proc{|c,level|
              c.sort {|a,b|
                  ascore = compute_comment_score a
                  bscore = compute_comment_score b
                  if ascore == bscore
                      # If score is the same favor newer comments
                      b['ctime'].to_i <=> a['ctime'].to_i
                  else
                      # If score is different order by score.
                      # FIXME: do something smarter favouring newest comments
                      # but only in the short time.
                      bscore <=> ascore
                  end
              }
          })
      end
      $user = nil
      auth_user(request.cookies['auth'])
      increment_karma_if_needed if $user
  end

end