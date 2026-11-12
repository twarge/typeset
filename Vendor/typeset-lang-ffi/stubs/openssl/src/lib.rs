//! Deliberately empty. On Apple platforms TLS goes through Security.framework
//! (native-tls picks it by `target_vendor = "apple"`), so nothing calls into
//! OpenSSL; this only keeps the real crate, and the OpenSSL installation its
//! build script demands, out of the visionOS build.
