

#import <Foundation/Foundation.h>

@interface MTDatacenterAddress : NSObject <NSCoding, NSCopying>

@property (nonatomic, strong, readonly) NSString * _Nullable host;
@property (nonatomic, strong, readonly) NSString * _Nullable ip;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) bool preferForMedia;
@property (nonatomic, readonly) bool restrictToTcp;
@property (nonatomic, readonly) bool cdn;
@property (nonatomic, readonly) bool preferForProxy;
@property (nonatomic, strong, readonly) NSData * _Nullable secret;

/// Non-nil only for a WebSocket endpoint: the HTTP path of the WebSocket upgrade
/// (e.g. "/apiws"). `ip` is then the endpoint host name and `port` its TLS port; there is
/// no MTProxy secret, and the address is reached with a WebSocket connection interface
/// (see MTContext.webSocketAddressesProvider) rather than by a plain TCP socket.
@property (nonatomic, strong, readonly) NSString * _Nullable webSocketPath;

- (instancetype _Nonnull)initWithIp:(NSString * _Nonnull)ip port:(uint16_t)port preferForMedia:(bool)preferForMedia restrictToTcp:(bool)restrictToTcp cdn:(bool)cdn preferForProxy:(bool)preferForProxy secret:(NSData * _Nullable)secret;

- (instancetype _Nonnull)initWithWebSocketIp:(NSString * _Nonnull)ip port:(uint16_t)port path:(NSString * _Nonnull)path preferForMedia:(bool)preferForMedia;

- (bool)isWebSocket;

- (BOOL)isEqualToAddress:(MTDatacenterAddress * _Nonnull)other;
- (BOOL)isIpv6;

@end
