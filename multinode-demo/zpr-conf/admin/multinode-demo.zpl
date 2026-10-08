# http://ociweb.demo
Define OciWeb as a service with device.zpr.adapter.cn:'ociweb.demo'.

# http://premweb.demo
Define PremWeb as a service with device.zpr.adapter.cn:'premweb.demo'.

provide OciWeb at ociweb.demo over TCP 80.
  allow access:cloud users.
  allow access:all users.

provide PremWeb at premweb.demo over TCP 80.
  allow access:onprem users.
  allow access:all users.
