FROM python:3.12-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      poppler-utils \
      tesseract-ocr \
      tesseract-ocr-eng \
      tesseract-ocr-rus && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /worker
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . ./

CMD ["python", "-m", "pytest"]
