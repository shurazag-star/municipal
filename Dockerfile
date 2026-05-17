FROM ruby:3.3.6

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      fontconfig \
      fonts-dejavu \
      fonts-liberation \
      fonts-noto-core \
      libpq-dev \
      libreoffice-writer \
      nodejs \
      poppler-utils \
      postgresql-client \
      python3 \
      python3-venv \
      tesseract-ocr \
      tesseract-ocr-eng \
      tesseract-ocr-rus && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /rails

COPY parser_worker/requirements.txt /tmp/parser_worker_requirements.txt
RUN python3 -m venv /opt/parser-venv && \
    /opt/parser-venv/bin/pip install --no-cache-dir -r /tmp/parser_worker_requirements.txt

ENV PARSER_WORKER_PYTHON=/opt/parser-venv/bin/python
ENV PARSER_WORKER_ROOT=/parser_worker
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_SERVE_STATIC_FILES=true

COPY rails_app/Gemfile rails_app/Gemfile.lock* ./
RUN bundle install

COPY parser_worker /parser_worker
COPY rails_app ./

EXPOSE 3000
CMD ["bash", "-lc", "bundle exec rails server -b 0.0.0.0 -p ${PORT:-3000}"]
