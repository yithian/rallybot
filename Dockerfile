
# rallybot
FROM openshift/base-centos7

# TODO: Put the maintainer name in the image metadata
MAINTAINER Alex Chvatal <yith@yuggoth.space>

# TODO: Rename the builder environment variable to inform users about application you provide them
ENV BUILDER_VERSION 1.0

# TODO: Set labels used in OpenShift to describe the builder image
LABEL io.k8s.description="irc bot for communicating with Rally" \
      io.k8s.display-name="rallybot 0.1.0" \
      #io.openshift.expose-services="8080:http" \
      io.openshift.tags="builder,irc,rallybot."

# TODO: Install required packages here:
RUN yum install -y ruby ruby-devel rubygems json && yum clean all -y && gem install bundler

# TODO (optional): Copy the builder files into /opt/app-root
# COPY ./<builder_folder>/ /opt/app-root/

# TODO: Copy the S2I scripts to /usr/libexec/s2i, since openshift/base-centos7 image sets io.openshift.s2i.scripts-url label that way, or update that label
COPY ./.s2i/bin/ /usr/libexec/s2i

# TODO: Drop the root user and make the content of /opt/app-root owned by user 1001
RUN chown -R 1001:1001 /opt/app-root

# This default user is created in the openshift/base-centos7 image
USER 1001

# TODO: Set the default port for applications built using this image
# EXPOSE 8080

# TODO: Set the default CMD for the image
CMD ["/usr/libexec/s2i/usage"]
