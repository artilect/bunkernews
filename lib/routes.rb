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

    get '/' do
        redirect "/login" unless $user

        H.set_title "Top News - #{SiteName}"
        news,numitems = get_top_news
        H.page {
            H.h2 {"Top news"}+news_list_to_html(news)
        }
    end

    # This poses a problem. Nice to have, but how to make it private?
    #
    get '/rss' do
        content_type 'text/xml', :charset => 'utf-8'
        news,count = get_latest_news
        H.rss(:version => "2.0", "xmlns:atom" => "http://www.w3.org/2005/Atom") {
            H.channel {
                H.title {
                    "#{SiteName}"
                } + " " +
                H.link {
                    "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}"
                } + " " +
                H.description {
                    "Description pending"
                } + " " +
                news_list_to_rss(news)
            }
        }
    end

    get '/latest' do
      redirect "/login" unless $user

      redirect '/latest/0'
    end

    get '/latest/:start' do
      redirect "/login" unless $user

        start = params[:start].to_i
        H.set_title "Latest news - #{SiteName}"
        paginate = {
            :get => Proc.new {|start,count|
                get_latest_news(start,count)
            },
            :render => Proc.new {|item| news_to_html(item)},
            :start => start,
            :perpage => LatestNewsPerPage,
            :link => "/latest/$"
        }
        H.page {
            H.h2 {"Latest news"}+
            H.section(:id => "newslist") {
                list_items(paginate)
            }
        }
    end

    get '/saved/:start' do
        redirect "/login" if !$user
        start = params[:start].to_i
        H.set_title "Saved news - #{SiteName}"
        paginate = {
            :get => Proc.new {|start,count|
                get_saved_news($user['id'],start,count)
            },
            :render => Proc.new {|item| news_to_html(item)},
            :start => start,
            :perpage => SavedNewsPerPage,
            :link => "/saved/$"
        }
        H.page {
            H.h2 {"Your saved news"}+
            H.section(:id => "newslist") {
                list_items(paginate)
            }
        }
    end

    get '/usercomments/:username/:start' do
      redirect "/login" unless $user

        start = params[:start].to_i
        user = get_user_by_username(params[:username])
        halt(404,"Non existing user") if !user

        H.set_title "#{H.entities user['username']} comments - #{SiteName}"
        paginate = {
            :get => Proc.new {|start,count|
                get_user_comments(user['id'],start,count)
            },
            :render => Proc.new {|comment|
                u = get_user_by_id(comment["user_id"]) || DeletedUser
                comment_to_html(comment,u)
            },
            :start => start,
            :perpage => UserCommentsPerPage,
            :link => "/usercomments/#{H.urlencode user['username']}/$"
        }
        H.page {
            H.h2 {"#{H.entities user['username']} comments"}+
            H.div("id" => "comments") {
                list_items(paginate)
            }
        }
    end

    get '/replies' do
        redirect "/login" if !$user
        comments,count = get_user_comments($user['id'],0,SubthreadsInRepliesPage)
        H.set_title "Your threads - #{SiteName}"
        H.page {
            $r.hset("user:#{$user['id']}","replies",0)
            H.h2 {"Your threads"}+
            H.div("id" => "comments") {
                aux = ""
                comments.each{|c|
                    aux << render_comment_subthread(c)
                }
                aux
            }
        }
    end

    get '/login' do
        H.set_title "Login - #{SiteName}"
        H.page {
            H.div(:id => "login") {
                H.form(:name=>"f") {
                    H.h2 { "Login" }+
                    H.ul do
                      H.li { H.input(:id => "username", :name => "username", :placeholder => "Username") }+
                      H.li { H.input(:type => "password", :id => "password", :name => "password", :placeholder => "Password") }+
                      H.li(:class=>"submit") { H.input(:type => "submit", :name => "do_login", :value => "Login") }
                      # H.li { H.checkbox(:name => "register", :value => "1") }
                    end
                }
            }+
            H.div(:id => "errormsg"){}+
            H.script() {'
                $(function() {
                    $("form[name=f]").submit(login);
                });
            '}
        }
    end

    get '/you_have_been_forbnitzed' do
        H.set_title "Welcome to #{SiteName}!"
        H.page {
            H.div(:id => "login") {
                H.form(:name=>"f") {
                    H.h2 { "Welcome!" }+
                    H.ul do
                      H.li { H.input(:id => "username", :name => "username", :placeholder => "Username") }+
                      H.li { H.input(:type => "password", :id => "password", :name => "password", :placeholder => "Password") }+
                      H.li(:class=>"submit") { H.input(:type => "submit", :name => "do_login", :value => "Create account") }
                    end+
                    H.input(:name => "register", :value => "1", :type => "hidden" )
                }
            }+
            H.div(:id => "errormsg"){}+
            H.script() {'
                $(function() {
                    $("form[name=f]").submit(login);
                });
            '}
        }
    end

    get '/submit' do
        redirect "/login" if !$user
        H.set_title "Submit a new story - #{SiteName}"
        H.page {
            H.h2 {"Submit a new story"}+
            H.div(:id => "submitform") {
                H.form(:name=>"f") {
                    H.input(:type => "hidden", :name => "news_id", :value => -1)+
                    H.input(:placeholder => "Title", :id => "title", :name => "title", :size => 80, :value => (params[:t] ? H.entities(params[:t]) : ""))+H.br+
                    H.input(:placeholder => "URL...", :id => "url", :name => "url", :size => 60, :value => (params[:u] ? H.entities(params[:u]) : ""))+H.br+
                    H.textarea(:placeholder => "...or your own post", :id => "text", :name => "text", :cols => 60, :rows => 10) {}+
                    H.input(:type => "submit", :name => "do_submit", :value => "Submit")
                }
            }+
            H.div(:id => "errormsg"){}+
            H.p {
                bl = "javascript:window.location=%22#{SiteUrl}/submit?u=%22+encodeURIComponent(document.location)+%22&t=%22+encodeURIComponent(document.title)"
                "Submitting news is simpler using the "+
                H.a(:href => bl) {
                    "bookmarklet"
                }+
                " (drag the link to your browser toolbar)"
            }+
            H.script() {'
                $(function() {
                    $("input[name=do_submit]").click(submit);
                });
            '}
        }
    end

    get '/logout' do
        if $user and check_api_secret
            update_auth_token($user["id"])
        end
        redirect "/"
    end

    get "/news/:news_id" do
      redirect "/login" unless $user
        news = get_news_by_id(params["news_id"])
        halt(404,"404 - This news does not exist.") if !news
        # Show the news text if it is a news without URL.
        if !news_domain(news)
            c = {
                "body" => news_text(news),
                "ctime" => news["ctime"],
                "user_id" => news["user_id"],
                "thread_id" => news["id"],
                "topcomment" => true
            }
            user = get_user_by_id(news["user_id"]) || DeletedUser
            top_comment = H.topcomment {comment_to_html(c,user)}
        else
            top_comment = ""
        end
        H.set_title "#{H.entities news["title"]} - #{SiteName}"
        H.page {
            H.section(:id => "newslist") {
                news_to_html(news)
            }+top_comment+
            if $user
                H.div(:id => "create_comment") {
                  H.form(:name=>"f" ) {
                      H.inputhidden(:name => "news_id", :value => news["id"])+
                      H.inputhidden(:name => "comment_id", :value => -1)+
                      H.inputhidden(:name => "parent_id", :value => -1)+
                      H.textarea(:name => "comment") {}+H.br+
                      H.input(:type => "submit", :name => "post_comment", :value => "Send comment")
                  }+H.div(:id => "errormsg"){}
                }
            else
                H.br
            end +
            render_comments_for_news(news["id"])+
            H.script() {'
                $(function() {
                    $("input[name=post_comment]").click(post_comment);
                });
            '}
        }
    end

    get "/comment/:news_id/:comment_id" do
      redirect "/login" unless $user
        news = get_news_by_id(params["news_id"])
        halt(404,"404 - This news does not exist.") if !news
        comment = Comments.fetch(params["news_id"],params["comment_id"])
        halt(404,"404 - This comment does not exist.") if !comment
        H.page {
            H.section(:id => "newslist") {
                news_to_html(news)
            }+
            render_comment_subthread(comment, H.h2 {"Replies"})
        }
    end

    def render_comment_subthread(comment,sep="")
        H.div(:class => "singlecomment") {
            u = get_user_by_id(comment["user_id"]) || DeletedUser
            comment_to_html(comment,u)
        }+H.div(:class => "commentreplies") {
            sep+
            render_comments_for_news(comment['thread_id'],comment["id"].to_i)
        }
    end

    get "/reply/:news_id/:comment_id" do
        redirect "/login" if !$user
        news = get_news_by_id(params["news_id"])
        halt(404,"404 - This news does not exist.") if !news
        comment = Comments.fetch(params["news_id"],params["comment_id"])
        halt(404,"404 - This comment does not exist.") if !comment
        user = get_user_by_id(comment["user_id"]) || DeletedUser

        H.set_title "Reply to comment - #{SiteName}"
        H.page {
            news_to_html(news)+
            comment_to_html(comment,user)+
            H.div(:id => "create_comment") {
              H.form(:name=>"f") {
                  H.inputhidden(:name => "news_id", :value => news["id"])+
                  H.inputhidden(:name => "comment_id", :value => -1)+
                  H.inputhidden(:name => "parent_id", :value => params["comment_id"])+
                  H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
                  H.input(:type => "submit", :name => "post_comment", :value => "Reply")
              }+H.div(:id => "errormsg"){}+
              H.script() {'
                  $(function() {
                      $("input[name=post_comment]").click(post_comment);
                  });
              '}
            }
        }
    end

    get "/editcomment/:news_id/:comment_id" do
        redirect "/login" if !$user
        news = get_news_by_id(params["news_id"])
        halt(404,"404 - This news does not exist.") if !news
        comment = Comments.fetch(params["news_id"],params["comment_id"])
        halt(404,"404 - This comment does not exist.") if !comment
        user = get_user_by_id(comment["user_id"]) || DeletedUser
        halt(500,"Permission denied.") if $user['id'].to_i != user['id'].to_i

        H.set_title "Edit comment - #{SiteName}"
        H.page {
            news_to_html(news)+
            comment_to_html(comment,user)+
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => news["id"])+
                H.inputhidden(:name => "comment_id",:value => params["comment_id"])+
                H.inputhidden(:name => "parent_id", :value => -1)+
                H.textarea(:name => "comment", :cols => 60, :rows => 10) {
                    H.entities comment['body']
                }+H.br+
                H.button(:name => "post_comment", :value => "Edit")
            }+H.div(:id => "errormsg"){}+
            H.note {
                "Note: to remove the comment remove all the text and press Edit."
            }+
            H.script() {'
                $(function() {
                    $("input[name=post_comment]").click(post_comment);
                });
            '}
        }
    end

    get "/editnews/:news_id" do
        redirect "/login" if !$user
        news = get_news_by_id(params["news_id"])
        halt(404,"404 - This news does not exist.") if !news
        halt(500,"Permission denied.") if $user['id'].to_i != news['user_id'].to_i

        if news_domain(news)
            text = ""
        else
            text = news_text(news)
            news['url'] = ""
        end
        H.set_title "Edit news - #{SiteName}"
        H.page {
            news_to_html(news)+
            H.div(:id => "submitform") {
                H.form(:name=>"f") {
                    H.inputhidden(:name => "news_id", :value => news['id'])+
                    H.label(:for => "title") {"title"}+
                    H.inputtext(:id => "title", :name => "title", :size => 80,
                                :value => H.entities(news['title']))+H.br+
                    H.label(:for => "url") {"url"}+H.br+
                    H.inputtext(:id => "url", :name => "url", :size => 60,
                                :value => H.entities(news['url']))+H.br+
                    "or if you don't have an url type some text"+
                    H.br+
                    H.label(:for => "text") {"text"}+
                    H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {
                        H.entities(text)
                    }+H.br+
                    H.checkbox(:name => "del", :value => "1")+
                    "delete this news"+H.br+
                    H.button(:name => "edit_news", :value => "Edit")
                }
            }+
            H.div(:id => "errormsg"){}+
            H.script() {'
                $(function() {
                    $("input[name=edit_news]").click(submit);
                });
            '}
        }
    end

    get "/user/:username" do
      redirect "/login" unless $user
        user = get_user_by_username(params[:username])
        halt(404,"Non existing user") if !user
        posted_news,posted_comments = $r.pipelined {
            $r.zcard("user.posted:#{user['id']}")
            $r.zcard("user.comments:#{user['id']}")
        }
        H.set_title "#{H.entities user['username']} - #{SiteName}"
        owner = $user && ($user['id'].to_i == user['id'].to_i)
        H.page {
            H.div(:class => "userinfo") {
                H.span(:class => "avatar") {
                    email = user["email"] || ""
                    digest = Digest::MD5.hexdigest(email)
                    H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
                }+" "+
                H.h2 {H.entities user['username']}+
                H.pre {
                    H.entities user['about']
                }+
                H.ul {
                    H.li {
                        H.b {"created "}+
                        "#{(Time.now.to_i-user['ctime'].to_i)/(3600*24)} days ago"
                    }+
                    H.li {H.b {"karma "}+ "#{user['karma']} points"}+
                    H.li {H.b {"posted news "}+posted_news.to_s}+
                    H.li {H.b {"posted comments "}+posted_comments.to_s}+
                    if owner
                        H.li {H.a(:href=>"/saved/0") {"saved news"}}
                    else "" end+
                    H.li {
                        H.a(:href=>"/usercomments/"+H.urlencode(user['username'])+
                                   "/0") {
                            "user comments"
                        }
                    }
                }
            }+if owner
                H.form(:name=>"f", :id => "usersettings" ) {
                    H.inputtext(:id => "email", :name => "email", :size => 40,
                                :value => H.entities(user['email']), :placeholder => "Email (not visible, used for gravatar)")+H.br+
                    H.inputpass(:name => "password", :size => 40, :type => "password", :placeholder => "New password" )+H.br+
                    H.textarea(:id => "about", :name => "about", :cols => 60, :rows => 10, :placeholder => "About..."){
                        H.entities(user['about'])
                    }+H.br+
                    H.input(:type => "submit", :name => "update_profile", :value => "Update profile")
                }+
                H.div(:id => "errormsg"){}+
                H.script() {'
                    $(function() {
                        $("input[name=update_profile]").click(update_profile);
                    });
                '}
            else "" end
        }
    end

end