#import "PairingManager.h"

@implementation PairingManager

+ (instancetype)sharedManager {
    static PairingManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PairingManager alloc] init];
    });
    return instance;
}

- (NSString *)getLocalBluetoothAddress {
    // Get local Bluetooth adapter address
    IOBluetoothHostController *controller = [IOBluetoothHostController defaultController];
    if (!controller) {
        NSLog(@"[PairingManager] Failed to get Bluetooth controller");
        return nil;
    }
    
    NSString *address = [controller addressAsString];
    NSLog(@"[PairingManager] Local Bluetooth address: %@", address);
    return address;
}

- (void)storePairedController:(NSString *)macAddress name:(NSString *)name {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *pairedControllers = [[defaults dictionaryForKey:@"PairedControllers"] mutableCopy];
    
    if (!pairedControllers) {
        pairedControllers = [NSMutableDictionary dictionary];
    }
    
    pairedControllers[macAddress] = @{
        @"name": name ?: @"Joy-Con",
        @"pairedDate": [NSDate date],
        @"macAddress": macAddress
    };
    
    [defaults setObject:pairedControllers forKey:@"PairedControllers"];
    [defaults synchronize];
    
    NSLog(@"[PairingManager] Stored paired controller: %@ (%@)", name, macAddress);
}

- (NSArray<NSDictionary *> *)getPairedControllers {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *pairedControllers = [defaults dictionaryForKey:@"PairedControllers"];
    
    if (!pairedControllers) {
        return @[];
    }
    
    return [pairedControllers allValues];
}

- (BOOL)isControllerPaired:(NSString *)macAddress {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *pairedControllers = [defaults dictionaryForKey:@"PairedControllers"];
    return pairedControllers[macAddress] != nil;
}

- (void)removePairedController:(NSString *)macAddress {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *pairedControllers = [[defaults dictionaryForKey:@"PairedControllers"] mutableCopy];
    
    if (pairedControllers) {
        [pairedControllers removeObjectForKey:macAddress];
        [defaults setObject:pairedControllers forKey:@"PairedControllers"];
        [defaults synchronize];
        NSLog(@"[PairingManager] Removed paired controller: %@", macAddress);
    }
}

// Helper: Convert MAC address string to bytes
- (NSData *)macStringToBytes:(NSString *)macString {
    NSString *normalized = [[macString stringByReplacingOccurrencesOfString:@"-" withString:@""]
                                      stringByReplacingOccurrencesOfString:@":" withString:@""];
    normalized = [normalized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalized.length != 12) {
        NSLog(@"[PairingManager] Invalid MAC address format: %@", macString);
        return nil;
    }
    
    uint8_t bytes[6];
    for (int i = 0; i < 6; i++) {
        NSString *component = [normalized substringWithRange:NSMakeRange(i * 2, 2)];
        NSScanner *scanner = [NSScanner scannerWithString:component];
        unsigned int byte;
        if (![scanner scanHexInt:&byte]) {
            NSLog(@"[PairingManager] Invalid MAC byte in address: %@", macString);
            return nil;
        }
        bytes[5 - i] = (uint8_t)byte;
    }
    
    return [NSData dataWithBytes:bytes length:6];
}

- (NSData *)generateMACBindingStep1:(NSString *)mac1 mac2:(NSString *)mac2 {
    // Command from Joy2Win: 15 91 01 01 00 0E 00 00 00 02 [mac1_6bytes] [mac2_6bytes]
    uint8_t cmd[] = {
        0x15, 0x91, 0x01, 0x01, 0x00, 0x0E, 0x00, 0x00,
        0x00, 0x02
    };
    
    NSMutableData *data = [NSMutableData dataWithBytes:cmd length:sizeof(cmd)];
    
    // Append MAC 1
    NSData *mac1Bytes = [self macStringToBytes:mac1];
    if (mac1Bytes) {
        [data appendData:mac1Bytes];
    } else {
        // Fallback: zeros
        uint8_t zeros[6] = {0};
        [data appendBytes:zeros length:6];
    }
    
    // Append MAC 2
    NSData *mac2Bytes = nil;
    if (mac2 && ![mac2 isEqualToString:mac1]) {
        mac2Bytes = [self macStringToBytes:mac2];
    }
    if (mac2Bytes) {
        [data appendData:mac2Bytes];
    } else if (mac1Bytes && mac1Bytes.length == 6) {
        NSMutableData *derivedMac2 = [mac1Bytes mutableCopy];
        uint8_t *bytes = (uint8_t *)derivedMac2.mutableBytes;
        bytes[0] = (uint8_t)(bytes[0] - 1);
        [data appendData:derivedMac2];
    } else {
        uint8_t zeros[6] = {0};
        [data appendBytes:zeros length:6];
    }
    
    NSLog(@"[PairingManager] Generated MAC binding step 1 (%lu bytes)", (unsigned long)data.length);
    return data;
}

- (NSData *)generateMACBindingStep2 {
    // Fixed blob from Joy2Win
    uint8_t cmd[] = {
        0x15, 0x91, 0x01, 0x04, 0x00, 0x11, 0x00, 0x00,
        0x00, 0x08, 0x06, 0x5A, 0x60, 0xE9, 0x02, 0xE4,
        0xE1, 0x02, 0x02, 0x9E, 0x3F, 0xA3, 0x9A, 0x78, 0xD1
    };
    return [NSData dataWithBytes:cmd length:sizeof(cmd)];
}

- (NSData *)generateMACBindingStep3 {
    // Fixed blob from Joy2Win
    uint8_t cmd[] = {
        0x15, 0x91, 0x01, 0x02, 0x00, 0x11, 0x00, 0x00,
        0x00, 0x93, 0x4E, 0x58, 0x0F, 0x16, 0x3A, 0xEE,
        0xCF, 0xB5, 0x75, 0xFC, 0x91, 0x36, 0xB2, 0x2F, 0xBB
    };
    return [NSData dataWithBytes:cmd length:sizeof(cmd)];
}

- (NSData *)generateMACBindingStep4 {
    // Commit command
    uint8_t cmd[] = {
        0x15, 0x91, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00
    };
    return [NSData dataWithBytes:cmd length:sizeof(cmd)];
}

@end
