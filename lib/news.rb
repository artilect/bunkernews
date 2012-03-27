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
    # News
    ################################################################################

    # Fetch one or more (if an Array is passed) news from Redis by id.
    # Note that we also load other informations about the news like
    # the username of the poster and other informations needed to render
    # the news into HTML.
    #
    # Doing this in a centralized way offers us the ability to exploit
    # Redis pipelining.
    def get_news_by_id(news_ids,opt={})
        result = []
        if !news_ids.is_a? Array
            opt[:single] = true
            news_ids = [news_ids]
        end
        news = $r.pipelined {
            news_ids.each{|nid|
                $r.hgetall("news:#{nid}")
            }
        }
        return [] if !news # Can happen only if news_ids is an empty array.

        # Remove empty elements
        news = news.select{|x| x.length > 0}
        if news.length == 0
            return opt[:single] ? nil : []
        end

        # Get all the news
        $r.pipelined {
            news.each{|n|
                # Adjust rank if too different from the real-time value.
                hash = {}
                n.each_slice(2) {|k,v|
                    hash[k] = v
                }
                update_news_rank_if_needed(hash) if opt[:update_rank]
                result << hash
            }
        }

        # Get the associated users information
        usernames = $r.pipelined {
            result.each{|n|
                $r.hget("user:#{n["user_id"]}","username")
            }
        }
        result.each_with_index{|n,i|
            n["username"] = usernames[i]
        }

        # Load $User vote information if we are in the context of a
        # registered user.
        if $user
            votes = $r.pipelined {
                result.each{|n|
                    $r.zscore("news.up:#{n["id"]}",$user["id"])
                    $r.zscore("news.down:#{n["id"]}",$user["id"])
                }
            }
            result.each_with_index{|n,i|
                if votes[i*2]
                    n["voted"] = :up
                elsif votes[(i*2)+1]
                    n["voted"] = :down
                end
            }
        end

        # Return an array if we got an array as input, otherwise
        # the single element the caller requested.
        opt[:single] ? result[0] : result
    end

    # Vote the specified news in the context of a given user.
    # type is either :up or :down
    # 
    # The function takes care of the following:
    # 1) The vote is not duplicated.
    # 2) That the karma is decreased from voting user, accordingly to vote type.
    # 3) That the karma is transfered to the author of the post, if different.
    # 4) That the news score is updaed.
    #
    # Return value: two return values are returned: rank,error
    #
    # If the fucntion is successful rank is not nil, and represents the news karma
    # after the vote was registered. The error is set to nil.
    #
    # On error the returned karma is false, and error is a string describing the
    # error that prevented the vote.
    def vote_news(news_id,user_id,vote_type)
        # Fetch news and user
        user = ($user and $user["id"] == user_id) ? $user : get_user_by_id(user_id)
        news = get_news_by_id(news_id)
        return false,"No such news or user." if !news or !user

        # Now it's time to check if the user already voted that news, either
        # up or down. If so return now.
        if $r.zscore("news.up:#{news_id}",user_id) or
           $r.zscore("news.down:#{news_id}",user_id)
           return false,"Duplicated vote."
        end

        # Check if the user has enough karma to perform this operation
        if $user['id'] != news['user_id']
            if (vote_type == :up and
                 (get_user_karma(user_id) < NewsUpvoteMinKarma)) or
               (vote_type == :down and
                 (get_user_karma(user_id) < NewsDownvoteMinKarma))
                return false,"You don't have enough karma to vote #{vote_type}"
            end
        end

        # News was not already voted by that user. Add the vote.
        # Note that even if there is a race condition here and the user may be
        # voting from another device/API in the time between the ZSCORE check
        # and the zadd, this will not result in inconsistencies as we will just
        # update the vote time with ZADD.
        if $r.zadd("news.#{vote_type}:#{news_id}", Time.now.to_i, user_id)
            $r.hincrby("news:#{news_id}",vote_type,1)
        end
        $r.zadd("user.saved:#{user_id}", Time.now.to_i, news_id) if vote_type == :up

        # Compute the new values of score and karma, updating the news accordingly.
        score = compute_news_score(news)
        news["score"] = score
        rank = compute_news_rank(news)
        $r.hmset("news:#{news_id}",
            "score",score,
            "rank",rank)
        $r.zadd("news.top",rank,news_id)

        # Remove some karma to the user if needed, and transfer karma to the
        # news owner in the case of an upvote.
        if $user['id'] != news['user_id']
            if vote_type == :up
                increment_user_karma_by(user_id,-NewsUpvoteKarmaCost)
                increment_user_karma_by(news['user_id'],NewsUpvoteKarmaTransfered)
            else
                increment_user_karma_by(user_id,-NewsDownvoteKarmaCost)
            end
        end

        return rank,nil
    end

    # Given the news compute its score.
    # No side effects.
    def compute_news_score(news)
        upvotes = $r.zrange("news.up:#{news["id"]}",0,-1,:withscores => true)
        downvotes = $r.zrange("news.down:#{news["id"]}",0,-1,:withscores => true)
        # FIXME: For now we are doing a naive sum of votes, without time-based
        # filtering, nor IP filtering.
        # We could use just ZCARD here of course, but I'm using ZRANGE already
        # since this is what is needed in the long term for vote analysis.
        score = (upvotes.length/2) - (downvotes.length/2)
        # Now let's add the logarithm of the sum of all the votes, since
        # something with 5 up and 5 down is less interesting than something
        # with 50 up and 50 donw.
        votes = upvotes.length/2+downvotes.length/2
        if votes > NewsScoreLogStart
            score += Math.log(votes-NewsScoreLogStart)*NewsScoreLogBooster
        end
        score
    end

    # Given the news compute its rank, that is function of time and score.
    #
    # The general forumla is RANK = SCORE / (AGE ^ AGING_FACTOR)
    def compute_news_rank(news)
        age = (Time.now.to_i - news["ctime"].to_i)
        rank = ((news["score"].to_f-1)*1000000)/((age+NewsAgePadding)**RankAgingFactor)
        rank = rank-1000 if (age > TopNewsAgeLimit)
        return rank
    end

    # Add a news with the specified url or text.
    #
    # If an url is passed but was already posted in the latest 48 hours the
    # news is not inserted, and the ID of the old news with the same URL is
    # returned.
    #
    # Return value: the ID of the inserted news, or the ID of the news with
    # the same URL recently added.
    def insert_news(title,url,text,user_id)
        # If we don't have an url but a comment, we turn the url into
        # text://....first comment..., so it is just a special case of
        # title+url anyway.
        textpost = url.length == 0
        if url.length == 0
            url = "text://"+text[0...CommentMaxLength]
        end
        # Check for already posted news with the same URL.
        if !textpost and (id = $r.get("url:"+url))
            return id.to_i
        end
        # We can finally insert the news.
        ctime = Time.new.to_i
        news_id = $r.incr("news.count")
        $r.hmset("news:#{news_id}",
            "id", news_id,
            "title", title,
            "url", url,
            "user_id", user_id,
            "ctime", ctime,
            "score", 0,
            "rank", 0,
            "up", 0,
            "down", 0,
            "comments", 0)
        # The posting user virtually upvoted the news posting it
        rank,error = vote_news(news_id,user_id,:up)
        # Add the news to the user submitted news
        $r.zadd("user.posted:#{user_id}",ctime,news_id)
        # Add the news into the chronological view
        $r.zadd("news.cron",ctime,news_id)
        # Add the news into the top view
        $r.zadd("news.top",rank,news_id)
        # Add the news url for some time to avoid reposts in short time
        $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
        # Set a timeout indicating when the user may post again
        $r.setex("user:#{$user['id']}:submitted_recently",NewsSubmissionBreak,'1')
        return news_id
    end

    # Edit an already existing news.
    #
    # On success the news_id is returned.
    # On success but when a news deletion is performed (empty title) -1 is returned.
    # On failure (for instance news_id does not exist or does not match
    #             the specified user_id) false is returned.
    def edit_news(news_id,title,url,text,user_id)
        news = get_news_by_id(news_id)
        return false if !news or news['user_id'].to_i != user_id.to_i
        return false if !(news['ctime'].to_i > (Time.now.to_i - NewsEditTime))

        # If we don't have an url but a comment, we turn the url into
        # text://....first comment..., so it is just a special case of
        # title+url anyway.
        textpost = url.length == 0
        if url.length == 0
            url = "text://"+text[0...CommentMaxLength]
        end
        # Even for edits don't allow to change the URL to the one of a
        # recently posted news.
        if !textpost and url != news['url']
            return false if $r.get("url:"+url)
            # No problems with this new url, but the url changed
            # so we unblock the old one and set the block in the new one.
            # Otherwise it is easy to mount a DOS attack.
            $r.del("url:"+news['url'])
            $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
        end
        # Edit the news fields.
        $r.hmset("news:#{news_id}",
            "title", title,
            "url", url)
        return news_id
    end

    # Mark an existing news as removed.
    def del_news(news_id,user_id)
        news = get_news_by_id(news_id)
        return false if !news or news['user_id'].to_i != user_id.to_i
        return false if !(news['ctime'].to_i > (Time.now.to_i - NewsEditTime))

        $r.hmset("news:#{news_id}","del",1)
        $r.zrem("news.top",news_id)
        $r.zrem("news.cron",news_id)
        return true
    end

    # Return the host part of the news URL field.
    # If the url is in the form text:// nil is returned.
    def news_domain(news)
        su = news["url"].split("/")
        domain = (su[0] == "text:") ? nil : su[2]
    end

    # Assuming the news has an url in the form text:// returns the text
    # inside. Otherwise nil is returned.
    def news_text(news)
        su = news["url"].split("/")
        (su[0] == "text:") ? news["url"][7..-1] : nil
    end

    # Turn the news into its RSS representation
    # This function expects as input a news entry as obtained from
    # the get_news_by_id function.
    def news_to_rss(news)
        domain = news_domain(news)
        news = {}.merge(news) # Copy the object so we can modify it as we wish.
        news["ln_url"] = "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}/news/#{news["id"]}"
        news["url"] = news["ln_url"] if !domain

        H.item {
            H.title {
                H.entities news["title"]
            } + " " +
            H.guid {
                H.entities news["url"]
            } + " " +
            H.link {
                H.entities news["url"]
            } + " " +
            H.description {
                "<![CDATA[" +
                H.a(:href=>news["ln_url"]) {
                    "Comments"
                } + "]]>"
            } + " " +
            H.comments {
                H.entities news["ln_url"]
            }
        }+"\n"
    end


    # Turn the news into its HTML representation, that is
    # a linked title with buttons to up/down vote plus additional info.
    # This function expects as input a news entry as obtained from
    # the get_news_by_id function.
    def news_to_html(news)
        return H.article(:class => "deleted") {
            "[deleted news]"
        } if news["del"]
        domain = news_domain(news)
        news = {}.merge(news) # Copy the object so we can modify it as we wish.
        news["url"] = "/news/#{news["id"]}" if !domain
        upclass = "uparrow"
        downclass = "downarrow"
        if news["voted"] == :up
            upclass << " voted"
            downclass << " disabled"
        elsif news["voted"] == :down
            downclass << " voted"
            upclass << " disabled"
        end
        H.article("data-news-id" => news["id"]) {
            H.a(:href => "#up", :class => upclass) {
                "&#9650;"
            }+" "+
            H.h2 {
                H.a(:href=>news["url"]) {
                    H.entities news["title"]
                }
            }+" "+
            H.address {
                if domain
                    "at "+H.entities(domain)
                else "" end +
                if ($user and $user['id'].to_i == news['user_id'].to_i and
                    news['ctime'].to_i > (Time.now.to_i - NewsEditTime))
                    " " + H.a(:href => "/editnews/#{news["id"]}") {
                        "[edit]"
                    }
                else "" end
            }+
            H.a(:href => "#down", :class =>  downclass) {
                "&#9660;"
            }+
            H.p {
                "#{news["up"]} up and #{news["down"]} down, posted by "+
                H.username {
                    H.a(:href=>"/user/"+H.urlencode(news["username"])) {
                        H.entities news["username"]
                    }
                }+" "+str_elapsed(news["ctime"].to_i)+" "+
                H.a(:href => "/news/#{news["id"]}") {
                    news["comments"]+" comments"
                }
            }+
            if params and params[:debug] and $user and user_is_admin?($user)
                "id: "+news["id"].to_s+" "+
                "score: "+news["score"].to_s+" "+
                "rank: "+compute_news_rank(news).to_s+" "+
                "zset_rank: "+$r.zscore("news.top",news["id"]).to_s
            else "" end
        }+"\n"
    end

    # If 'news' is a list of news entries (Ruby hashes with the same fields of
    # the Redis hash representing the news in the DB) this function will render
    # the RSS needed to show this news.
    def news_list_to_rss(news)
        aux = ""
        news.each{|n|
            aux << news_to_rss(n)
        }
        aux
    end

    # If 'news' is a list of news entries (Ruby hashes with the same fields of
    # the Redis hash representing the news in the DB) this function will render
    # the HTML needed to show this news.
    def news_list_to_html(news)
        H.section(:id => "newslist") {
            aux = ""
            news.each{|n|
                aux << news_to_html(n)
            }
            aux
        }
    end

    # Updating the rank would require some cron job and worker in theory as
    # it is time dependent and we don't want to do any sorting operation at
    # page view time. But instead what we do is to compute the rank from the
    # score and update it in the sorted set only if there is some sensible error.
    # This way ranks are updated incrementally and "live" at every page view
    # only for the news where this makes sense, that is, top news.
    #
    # Note: this function can be called in the context of redis.pipelined {...}
    def update_news_rank_if_needed(n)
        real_rank = compute_news_rank(n)
        delta_rank = (real_rank-n["rank"].to_f).abs
        if delta_rank > 0.000001
            $r.hmset("news:#{n["id"]}","rank",real_rank)
            $r.zadd("news.top",real_rank,n["id"])
            n["rank"] = real_rank.to_s
        end
    end

    # Generate the main page of the web site, the one where news are ordered by
    # rank.
    # 
    # As a side effect thsi function take care of checking if the rank stored
    # in the DB is no longer correct (as time is passing) and updates it if
    # needed.
    #
    # This way we can completely avoid having a cron job adjusting our news
    # score since this is done incrementally when there are pageviews on the
    # site.
    def get_top_news(start=0,count=TopNewsPerPage)
        numitems = $r.zcard("news.top")
        news_ids = $r.zrevrange("news.top",start,start+(count-1))
        result = get_news_by_id(news_ids,:update_rank => true)
        # Sort by rank before returning, since we adjusted ranks during iteration.
        return result.sort{|a,b| b["rank"].to_f <=> a["rank"].to_f},numitems
    end

    # Get news in chronological order.
    def get_latest_news(start=0,count=LatestNewsPerPage)
        numitems = $r.zcard("news.cron")
        news_ids = $r.zrevrange("news.cron",start,start+(count-1))
        return get_news_by_id(news_ids,:update_rank => true),numitems
    end

    # Get saved news of current user
    def get_saved_news(user_id,start,count)
        numitems = $r.zcard("user.saved:#{user_id}").to_i
        news_ids = $r.zrevrange("user.saved:#{user_id}",start,start+(count-1))
        return get_news_by_id(news_ids),numitems
    end

end