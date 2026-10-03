# http://ociweb.demo
Define OciWeb as a service.

# http://premweb.demo
Define PremWeb as a service.

service OciWeb as json {"service_class":"OciWeb"}.
  allow access:cloud users.
  allow access:all users.

service PremWeb as json {"service_class":"PremWeb"}.
  allow access:onprem users.
  allow access:all users.
