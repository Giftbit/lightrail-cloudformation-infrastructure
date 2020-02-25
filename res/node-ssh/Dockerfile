FROM amazonlinux:2
RUN curl --silent --location https://rpm.nodesource.com/setup_10.x | bash -
RUN yum install -y git nodejs openssh-clients python37 zip
RUN curl https://bootstrap.pypa.io/get-pip.py | python3 -
RUN pip install awscli
