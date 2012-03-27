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
    # Comments
    ###############################################################################

    # This function has different behaviors, depending on the arguments:
    #
    # 1) If comment_id is -1 insert a new comment into the specified news.
    # 2) If comment_id is an already existing comment in the context of the
    #    specified news, updates the comment.
    # 3) If comment_id is an already existing comment in the context of the
    #    specified news, but the comment is an empty string, delete the comment.
    #
    # Return value:
    #
    # If news_id does not exist or comment_id is not -1 but neither a valid
    # comment for that news, nil is returned.
    # Otherwise an hash is returned with the following fields:
    #   news_id: the news id
    #   comment_id: the updated comment id, or the new comment id
    #   op: the operation performed: "insert", "update", or "delete"
    #
    # More informations:
    #
    # The parent_id is only used for inserts (when comment_id == -1), otherwise
    # is ignored.
    def insert_comment(news_id,user_id,comment_id,parent_id,body)
        news = get_news_by_id(news_id)
        return false if !news
        if comment_id == -1
            if parent_id.to_i != -1
                p = Comments.fetch(news_id,parent_id)
                return false if !p
            end
            comment = {"score" => 0,
                       "body" => body,
                       "parent_id" => parent_id,
                       "user_id" => user_id,
                       "ctime" => Time.now.to_i,
                       "up" => [user_id.to_i] };
            comment_id = Comments.insert(news_id,comment)
            return false if !comment_id
            $r.hincrby("news:#{news_id}","comments",1);
            $r.zadd("user.comments:#{user_id}",
                Time.now.to_i,
                news_id.to_s+"-"+comment_id.to_s);
            # increment_user_karma_by(user_id,KarmaIncrementComment)
            if p and $r.exists("user:#{p['user_id']}")
                $r.hincrby("user:#{p['user_id']}","replies",1)
            end
            return {
                "news_id" => news_id,
                "comment_id" => comment_id,
                "op" => "insert"
            }
        end

        # If we reached this point the next step is either to update or
        # delete the comment. So we make sure the user_id of the request
        # matches the user_id of the comment.
        # We also make sure the user is in time for an edit operation.
        c = Comments.fetch(news_id,comment_id)
        return false if !c or c['user_id'].to_i != user_id.to_i
        return false if !(c['ctime'].to_i > (Time.now.to_i - CommentEditTime))

        if body.length == 0
            return false if !Comments.del_comment(news_id,comment_id)
            $r.hincrby("news:#{news_id}","comments",-1);
            return {
                "news_id" => news_id,
                "comment_id" => comment_id,
                "op" => "delete"
            }
        else
            update = {"body" => body}
            update = {"del" => 0} if c['del'].to_i == 1
            return false if !Comments.edit(news_id,comment_id,update)
            return {
                "news_id" => news_id,
                "comment_id" => comment_id,
                "op" => "update"
            }
        end
    end

    # Compute the comment score
    def compute_comment_score(c)
        upcount = (c['up'] ? c['up'].length : 0)
        downcount = (c['down'] ? c['down'].length : 0)
        upcount-downcount
    end

    # Given a string returns the same string with all the urls converted into
    # HTML links. We try to handle the case of an url that is followed by a period
    # Like in "I suggest http://google.com." excluding the final dot from the link.
    def urls_to_links(s)
        urls = /((https?:\/\/|www\.)([-\w\.]+)+(:\d+)?(\/([\w\/_\.\-\%]*(\?\S+)?)?)?)/
        s.gsub(urls) {
            if $1[-1..-1] == '.'
                url = $1.chop
                '<a href="'+url+'">'+url+'</a>.'
            else
                '<a href="'+$1+'">'+$1+'</a>'
            end
        }
    end

    # Render a comment into HTML.
    # 'c' is the comment representation as a Ruby hash.
    # 'u' is the user, obtained from the user_id by the caller.
    def comment_to_html(c,u)
        indent = "margin-left:#{c['level'].to_i*CommentReplyShift}px"
        score = compute_comment_score(c)
        news_id = c['thread_id']

        if c['del'] and c['del'].to_i == 1
            return H.article(:style => indent,:class=>"commented deleted") {
                "[comment deleted]"
            }
        end
        show_edit_link = !c['topcomment'] &&
                    ($user && ($user['id'].to_i == c['user_id'].to_i)) &&
                    (c['ctime'].to_i > (Time.now.to_i - CommentEditTime))

        comment_id = "#{news_id}-#{c['id']}"
        H.article(:class => "comment", :style => indent,
                  "data-comment-id" => comment_id, :id => comment_id) {
            H.span(:class => "avatar") {
                email = u["email"] || ""
                digest = Digest::MD5.hexdigest(email)
                H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
            }+H.span(:class => "info") {
                H.span(:class => "username") {
                    H.a(:href=>"/user/"+H.urlencode(u["username"])) {
                        H.entities u["username"]
                    }
                }+" "+str_elapsed(c["ctime"].to_i)+". "+
                if !c['topcomment']
                    H.a(:href=>"/comment/#{news_id}/#{c["id"]}", :class=>"reply") {
                        "link"
                    }+" "
                else "" end +
                if $user and !c['topcomment']
                    H.a(:href=>"/reply/#{news_id}/#{c["id"]}", :class=>"reply") {
                        "reply"
                    }+" "
                else " " end +
                if !c['topcomment']
                    upclass = "uparrow"
                    downclass = "downarrow"
                    if $user and c['up'] and c['up'].index($user['id'].to_i)
                        upclass << " voted"
                        downclass << " disabled"
                    elsif $user and c['down'] and c['down'].index($user['id'].to_i)
                        downclass << " voted"
                        upclass << " disabled"
                    end
                    "#{score} points "+
                    H.a(:href => "#up", :class => upclass) {
                        "&#9650;"
                    }+" "+
                    H.a(:href => "#down", :class => downclass) {
                        "&#9660;"
                    }
                else " " end +
                if show_edit_link
                    H.a(:href=> "/editcomment/#{news_id}/#{c["id"]}",
                        :class =>"reply") {"edit"}+
                        " (#{
                            (CommentEditTime - (Time.now.to_i-c['ctime'].to_i))/60
                        } minutes left)"
                else "" end
            }+H.pre {
                urls_to_links H.entities(c["body"].strip)
            }
        }
    end

    def render_comments_for_news(news_id,root=-1)
        html = ""
        user = {}
        Comments.render_comments(news_id,root) {|c|
            user[c["id"]] = get_user_by_id(c["user_id"]) if !user[c["id"]]
            user[c["id"]] = DeletedUser if !user[c["id"]]
            u = user[c["id"]]
            html << comment_to_html(c,u)
        }
        H.div("id" => "comments") {html}
    end

    def vote_comment(news_id,comment_id,user_id,vote_type)
        user_id = user_id.to_i
        comment = Comments.fetch(news_id,comment_id)
        return false if !comment
        varray = (comment[vote_type.to_s] or [])
        return false if varray.index(user_id)
        varray << user_id
        return Comments.edit(news_id,comment_id,{vote_type.to_s => varray})
    end

    # Get comments in chronological order for the specified user in the
    # specified range.
    def get_user_comments(user_id,start,count)
        numitems = $r.zcard("user.comments:#{user_id}").to_i
        ids = $r.zrevrange("user.comments:#{user_id}",start,start+(count-1))
        comments = []
        ids.each{|id|
            news_id,comment_id = id.split('-')
            comment = Comments.fetch(news_id,comment_id)
            comments << comment if comment
        }
        [comments,numitems]
    end

end