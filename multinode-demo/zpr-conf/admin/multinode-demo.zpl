# http://ociweb.demo
Define OciWeb as a service.

# http://premweb.demo
Define PremWeb as a service.

service OciWeb as json {"service_class":"OciWeb"}.
  allow access:cloud users to access services.
  allow access:all users to access services.

service PremWeb as json {"service_class":"PremWeb"}.
  allow access:onprem users to access services.
  allow access:all users to access services.
