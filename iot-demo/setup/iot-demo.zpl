define OracleIoT as a service with device.zpr.adapter.cn:'egress.zpr.org'.
define VerifiedIoTDevice as a device with OCIApproved:true.

provide OracleIoT at oracle-iot.svc.zpr over TCP 1883.
  allow VerifiedIoTDevices.
