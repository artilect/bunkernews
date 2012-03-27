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

    ################################################################################
    # User and authentication
    ################################################################################

    # Try to authenticate the user, if the credentials are ok we populate the
    # $user global with the user information.
    # Otherwise $user is set to nil, so you can test for authenticated user
    # just with: if $user ...
    #
    # Return value: none, the function works by side effect.
    def auth_user(auth)
        return if !auth
        id = $r.get("auth:#{auth}")
        return if !id
        user = $r.hgetall("user:#{id}")
        $user = user if user.length > 0
    end

    # In Lamer News users get karma visiting the site.
    # Increment the user karma by KarmaIncrementAmount if the latest increment
    # was performed more than KarmaIncrementInterval seconds ago.
    #
    # Return value: none.
    #
    # Notes: this function must be called only in the context of a logged in
    #        user.
    #
    # Side effects: the user karma is incremented and the $user hash updated.
    def increment_karma_if_needed
        if $user['karma_incr_time'].to_i < (Time.now.to_i-KarmaIncrementInterval)
            userkey = "user:#{$user['id']}"
            $r.hset(userkey,"karma_incr_time",Time.now.to_i)
            increment_user_karma_by($user['id'],KarmaIncrementAmount)
        end
    end

    # Increment the user karma by the specified amount and make sure to
    # update $user to reflect the change if it is the same user id.
    def increment_user_karma_by(user_id,increment)
        userkey = "user:#{user_id}"
        $r.hincrby(userkey,"karma",increment)
        if $user and ($user['id'].to_i == user_id.to_i)
            $user['karma'] = $user['karma'].to_i + increment
        end
    end

    # Return the specified user karma.
    def get_user_karma(user_id)
        return $user['karma'].to_i if $user and (user_id.to_i == $user['id'].to_i)
        userkey = "user:#{user_id}"
        karma = $r.hget(userkey,"karma")
        karma ? karma.to_i : 0
    end

    # Return the hex representation of an unguessable 160 bit random number.
    def get_rand
        rand = "";
        File.open("/dev/urandom").read(20).each_byte{|x| rand << sprintf("%02x",x)}
        rand
    end

    # Create a new user with the specified username/password
    #
    # Return value: the function returns two values, the first is the
    #               auth token if the registration succeeded, otherwise
    #               is nil. The second is the error message if the function
    #               failed (detected testing the first return value).
    def create_user(username,password)
        if $r.exists("username.to.id:#{username.downcase}")
            return nil, "Username is busy, please try a different one."
        end
        if rate_limit_by_ip(3600*15,"create_user",request.ip)
            return nil, "Please wait some time before creating a new user."
        end
        id = $r.incr("users.count")
        auth_token = get_rand
        salt = get_rand
        $r.hmset("user:#{id}",
            "id",id,
            "username",username,
            "salt",salt,
            "password",hash_password(password,salt),
            "ctime",Time.now.to_i,
            "karma",UserInitialKarma,
            "about","",
            "email","",
            "auth",auth_token,
            "apisecret",get_rand,
            "flags","",
            "karma_incr_time",Time.new.to_i)
        $r.set("username.to.id:#{username.downcase}",id)
        $r.set("auth:#{auth_token}",id)
        return auth_token,nil
    end

    # Update the specified user authentication token with a random generated
    # one. This in other words means to logout all the sessions open for that
    # user.
    #
    # Return value: on success the new token is returned. Otherwise nil.
    # Side effect: the auth token is modified.
    def update_auth_token(user_id)
        user = get_user_by_id(user_id)
        return nil if !user
        $r.del("auth:#{user['auth']}")
        new_auth_token = get_rand
        $r.hmset("user:#{user_id}","auth",new_auth_token)
        $r.set("auth:#{new_auth_token}",user_id)
        return new_auth_token
    end

    # Turn the password into an hashed one, using PBKDF2 with HMAC-SHA1
    # and 160 bit output.
    def hash_password(password,salt)
        p = PBKDF2.new do |p|
            p.iterations = PBKDF2Iterations
            p.password = password
            p.salt = salt
            p.key_length = 160/8
        end
        p.hex_string
    end

    # Return the user from the ID.
    def get_user_by_id(id)
        $r.hgetall("user:#{id}")
    end

    # Return the user from the username.
    def get_user_by_username(username)
        id = $r.get("username.to.id:#{username.downcase}")
        return nil if !id
        get_user_by_id(id)
    end

    # Check if the username/password pair identifies an user.
    # If so the auth token and form secret are returned, otherwise nil is returned.
    def check_user_credentials(username,password)
        user = get_user_by_username(username)
        return nil if !user
        hp = hash_password(password,user['salt'])
        (user['password'] == hp) ? [user['auth'],user['apisecret']] : nil
    end

    # Has the user submitted a news story in the last `NewsSubmissionBreak` seconds?
    def submitted_recently
        allowed_to_post_in_seconds > 0
    end

    # Indicates when the user is allowed to submit another story after the last.
    def allowed_to_post_in_seconds
        $r.ttl("user:#{$user['id']}:submitted_recently")
    end

    # Add the specified set of flags to the user.
    # Returns false on error (non existing user), otherwise true is returned.
    #
    # Current flags:
    # 'a'   Administrator.
    # 'k'   Karma source, can transfer more karma than owned.
    # 'n'   Open links to new windows.
    #
    def user_add_flags(user_id,flags)
        user = get_user_by_id(user_id)
        return false if !user
        newflags = user['flags']
        flags.each_char{|flag|
            newflags << flag if not user_has_flags?(user,flag)
        }
        # Note: race condition here if somebody touched the same field
        # at the same time: very unlkely and not critical so not using WATCH.
        $r.hset("user:#{user['id']}","flags",newflags)
        true
    end

    # Check if the user has all the specified flags at the same time.
    # Returns true or false.
    def user_has_flags?(user,flags)
        flags.each_char {|flag|
            return false if not user['flags'].index(flag)
        }
        true
    end

    def user_is_admin?(user)
        user_has_flags?(user,"a")
    end

end