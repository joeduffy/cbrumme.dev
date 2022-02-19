FROM ruby:2.7.0

RUN apt-get update -y

# Install program to configure locales
RUN apt-get install -y locales
RUN dpkg-reconfigure locales && \
  locale-gen C.UTF-8 && \
  /usr/sbin/update-locale LANG=C.UTF-8

# Install needed default locale for Makefly
RUN echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && \
  locale-gen

# Set default locale for the environment
ENV LC_ALL C.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8

# Install the GitHub Pages and Jekyll requirements.
RUN gem install bundler
ADD ./Gemfile ./
RUN bundle install

# Add our content, build it, serve it.
VOLUME /site
WORKDIR /site
RUN jekyll build

EXPOSE 4000
ENTRYPOINT [ "bundle", "exec", "jekyll", "serve", "--incremental", "--host=0.0.0.0" ]
