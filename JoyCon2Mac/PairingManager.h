#ifndef PAIRING_MANAGER_H
#define PAIRING_MANAGER_H

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

@interface PairingManager : NSObject

// Singleton instance
+ (instancetype)sharedManager;

// Get local Mac Bluetooth address
- (NSString *)getLocalBluetoothAddress;

// Store paired controller
- (void)storePairedController:(NSString *)macAddress name:(NSString *)name;

// Get all paired controllers
- (NSArray<NSDictionary *> *)getPairedControllers;

// Check if controller is paired
- (BOOL)isControllerPaired:(NSString *)macAddress;

// Remove paired controller
- (void)removePairedController:(NSString *)macAddress;

// Generate MAC binding command sequences
- (NSData *)generateMACBindingStep1:(NSString *)mac1 mac2:(NSString *)mac2;
- (NSData *)generateMACBindingStep2;
- (NSData *)generateMACBindingStep3;
- (NSData *)generateMACBindingStep4;

@end

#endif // PAIRING_MANAGER_H
