Define AuthService as a service.

Define AuthSvcPing as a service with device.zpr.adapter.cn:'bas.zpr.org'.
Define NetAdmins   as users with color:blue.

Define WebService  as a service with user.bas_id:1234.

service AuthService as json {"service_class":"AuthService"}.
  allow zpr.adapter.cn: devices.

service AuthSvcPing as json {"service_class":"AuthSvcPing"}.
  allow color: users.

service WebService as json {"service_class":"WebService"}.
  allow color:green users.

provide VisaService at visa-admin.svc.zpr over TCP 443.
  allow NetAdmins.
