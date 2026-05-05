#import "BLEManager.h"
#import "PairingManager.h"
#include <iostream>
#include <cmath>

static const uint16_t NINTENDO_MANUFACTURER_ID = 0x0553;
static NSString *const UUID_INPUT = @"ab7de9be-89fe-49ad-828f-118f09df7fd2";
static NSString *const UUID_COMMAND = @"649d4ac9-8eb7-4e6c-af44-1ea54fe5f005";
static NSString *const UUID_RESPONSE = @"c765a961-d9d8-4d36-a20a-5315b111836a";

@interface JoyConPeripheralContext : NSObject
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, strong) CBCharacteristic *inputCharacteristic;
@property (nonatomic, strong) CBCharacteristic *commandCharacteristic;
@property (nonatomic, strong) CBCharacteristic *responseCharacteristic;
@property (nonatomic, strong) NSTimer *responseTimer;
@property (nonatomic, strong) NSMutableArray<NSData *> *commandQueue;
@property (nonatomic, strong) NSMutableArray<NSString *> *commandLabels;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *commandWaitsForProtocolResponse;
@property (nonatomic, assign) JoyConSide side;
@property (nonatomic, assign) BOOL initStarted;
@property (nonatomic, assign) BOOL isInitialized;
@property (nonatomic, assign) BOOL waitingForResponse;
@property (nonatomic, assign) BOOL commandInFlight;
@property (nonatomic, assign) BOOL currentCommandWaitsForProtocolResponse;
@property (nonatomic, assign) BOOL sideWasInferred;
@property (nonatomic, assign) BOOL characteristicsReady;
@property (nonatomic, assign) BOOL pairingPersistenceStarted;
@property (nonatomic, assign) BOOL startupLifecycleDone;
@property (nonatomic, assign) int initStep;
@property (nonatomic, assign) uint8_t ledMask;
@property (nonatomic, assign) NSUInteger inputPacketCount;
@property (nonatomic, assign) uint8_t currentCommandID;
@end

@implementation JoyConPeripheralContext
- (instancetype)init {
    self = [super init];
    if (self) {
        _commandQueue = [NSMutableArray array];
        _commandLabels = [NSMutableArray array];
        _commandWaitsForProtocolResponse = [NSMutableArray array];
    }
    return self;
}
@end

@implementation BLEManager {
    JoyConDataCallback _dataCallback;
    JoyConStatusCallback _statusCallback;
    JoyConTelemetryCallback _telemetryCallback;
    NSMutableDictionary<NSString *, JoyConPeripheralContext *> *_contextsByPeripheralID;
    NSMutableDictionary<NSString *, NSNumber *> *_sideByPeripheralID;
    NSMutableDictionary<NSString *, NSNumber *> *_reconnectAttemptsByPeripheralID;
    NSMutableDictionary<NSString *, NSDate *> *_lastConnectionAttemptByPeripheralID;
    NSMutableDictionary<NSString *, CBPeripheral *> *_pendingPeripheralsByID;
    NSMutableDictionary<NSString *, NSString *> *_pendingNamesByID;
    NSMutableDictionary<NSString *, NSNumber *> *_pendingRSSIByID;
    NSMutableDictionary<NSString *, NSNumber *> *_pendingSideWasInferredByID;
    NSMutableSet<NSString *> *_connectingPeripheralIDs;
    NSMutableArray<NSString *> *_pendingInitializationPeripheralIDs;
    NSString *_startupOwnerPeripheralID;
    BOOL _isShuttingDown;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.discoveredPeripherals = [NSMutableArray array];
        _contextsByPeripheralID = [NSMutableDictionary dictionary];
        _sideByPeripheralID = [NSMutableDictionary dictionary];
        _reconnectAttemptsByPeripheralID = [NSMutableDictionary dictionary];
        _lastConnectionAttemptByPeripheralID = [NSMutableDictionary dictionary];
        _pendingPeripheralsByID = [NSMutableDictionary dictionary];
        _pendingNamesByID = [NSMutableDictionary dictionary];
        _pendingRSSIByID = [NSMutableDictionary dictionary];
        _pendingSideWasInferredByID = [NSMutableDictionary dictionary];
        _connectingPeripheralIDs = [NSMutableSet set];
        _pendingInitializationPeripheralIDs = [NSMutableArray array];
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
    return self;
}

- (void)setDataCallback:(JoyConDataCallback)callback {
    _dataCallback = callback;
}

- (void)setStatusCallback:(JoyConStatusCallback)callback {
    _statusCallback = callback;
}

- (void)setTelemetryCallback:(JoyConTelemetryCallback)callback {
    _telemetryCallback = callback;
}

- (void)emitStatus:(const char *)status message:(const char *)message forContext:(JoyConPeripheralContext *)context {
    if (_statusCallback && context) {
        const char *name = context.peripheral.name ? [context.peripheral.name UTF8String] : "";
        _statusCallback(context.side, status, message ?: "", name);
    }
}

- (void)emitStatus:(const char *)status message:(const char *)message side:(JoyConSide)side name:(NSString *)name {
    if (_statusCallback) {
        _statusCallback(side, status, message ?: "", name ? [name UTF8String] : "");
    }
}

- (NSString *)hexStringForData:(NSData *)data maxBytes:(NSUInteger)maxBytes {
    if (!data) {
        return @"";
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = MIN(data.length, maxBytes);
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 3];
    for (NSUInteger i = 0; i < length; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
        if (i + 1 < length) {
            [hex appendString:@" "];
        }
    }
    if (data.length > maxBytes) {
        [hex appendFormat:@" ... (%lu bytes)", (unsigned long)data.length];
    }
    return hex;
}

- (NSString *)propertiesStringForCharacteristic:(CBCharacteristic *)characteristic {
    if (!characteristic) {
        return @"";
    }

    NSMutableArray<NSString *> *properties = [NSMutableArray array];
    CBCharacteristicProperties flags = characteristic.properties;
    if (flags & CBCharacteristicPropertyBroadcast) [properties addObject:@"broadcast"];
    if (flags & CBCharacteristicPropertyRead) [properties addObject:@"read"];
    if (flags & CBCharacteristicPropertyWriteWithoutResponse) [properties addObject:@"writeWithoutResponse"];
    if (flags & CBCharacteristicPropertyWrite) [properties addObject:@"write"];
    if (flags & CBCharacteristicPropertyNotify) [properties addObject:@"notify"];
    if (flags & CBCharacteristicPropertyIndicate) [properties addObject:@"indicate"];
    if (flags & CBCharacteristicPropertyAuthenticatedSignedWrites) [properties addObject:@"authenticatedSignedWrites"];
    if (flags & CBCharacteristicPropertyExtendedProperties) [properties addObject:@"extended"];
    if (flags & CBCharacteristicPropertyNotifyEncryptionRequired) [properties addObject:@"notifyEncryptionRequired"];
    if (flags & CBCharacteristicPropertyIndicateEncryptionRequired) [properties addObject:@"indicateEncryptionRequired"];
    return [properties componentsJoinedByString:@"|"];
}

- (void)emitTelemetry:(const char *)phase detail:(NSString *)detail forContext:(JoyConPeripheralContext *)context {
    if (_telemetryCallback && context) {
        const char *name = context.peripheral.name ? [context.peripheral.name UTF8String] : "";
        _telemetryCallback(context.side, phase, detail ? [detail UTF8String] : "", name);
    }
}

- (void)emitTelemetry:(const char *)phase detail:(NSString *)detail side:(JoyConSide)side name:(NSString *)name {
    if (_telemetryCallback) {
        _telemetryCallback(side, phase, detail ? [detail UTF8String] : "", name ? [name UTF8String] : "");
    }
}

- (void)startScanning {
    _isShuttingDown = NO;

    if (self.centralManager.state != CBManagerStatePoweredOn) {
        std::cout << "[BLE] Bluetooth not ready. Current state: " << (int)self.centralManager.state << std::endl;
        [self emitTelemetry:"scan.deferred"
                     detail:[NSString stringWithFormat:@"centralState=%ld", (long)self.centralManager.state]
                       side:JoyConSide::Left
                       name:nil];
        return;
    }

    std::cout << "[BLE] Scanning for left and right Joy-Con 2 controllers..." << std::endl;
    [self emitTelemetry:"scan.start" detail:@"allowDuplicates=true services=nil" side:JoyConSide::Left name:nil];
    [self emitStatus:"scanning" message:"Scanning for Joy-Con 2 controllers" side:JoyConSide::Left name:nil];
    [self emitStatus:"scanning" message:"Scanning for Joy-Con 2 controllers" side:JoyConSide::Right name:nil];
    [self.centralManager scanForPeripheralsWithServices:nil options:@{
        CBCentralManagerScanOptionAllowDuplicatesKey: @YES
    }];
}

- (void)stopScanning {
    [self.centralManager stopScan];
    std::cout << "[BLE] Stopped scanning." << std::endl;
    [self emitTelemetry:"scan.stop" detail:@"central scan stopped" side:JoyConSide::Left name:nil];
}

- (void)disconnect {
    _isShuttingDown = YES;
    [self emitTelemetry:"daemon.disconnect" detail:@"disconnect requested" side:JoyConSide::Left name:nil];
    [self stopScanning];
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [context.responseTimer invalidate];
        context.responseTimer = nil;
        if (context.peripheral.state != CBPeripheralStateDisconnected) {
            [self.centralManager cancelPeripheralConnection:context.peripheral];
        }
    }
    [_connectingPeripheralIDs removeAllObjects];
    [_pendingPeripheralsByID removeAllObjects];
    [_pendingNamesByID removeAllObjects];
    [_pendingRSSIByID removeAllObjects];
    [_pendingSideWasInferredByID removeAllObjects];
    [_pendingInitializationPeripheralIDs removeAllObjects];
    _startupOwnerPeripheralID = nil;
}

- (NSString *)keyForPeripheral:(CBPeripheral *)peripheral {
    return peripheral.identifier.UUIDString;
}

- (NSString *)labelForSide:(JoyConSide)side {
    return side == JoyConSide::Right ? @"Right" : @"Left";
}

- (BOOL)isNintendoAdvertisement:(NSDictionary<NSString *,id> *)advertisementData
                      peripheral:(CBPeripheral *)peripheral {
    NSString *deviceName = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"";
    NSString *lowerName = [deviceName lowercaseString];
    if ([lowerName containsString:@"nintendo"] ||
        [lowerName containsString:@"joy-con"] ||
        [lowerName containsString:@"joy con"] ||
        [lowerName containsString:@"joycon"] ||
        [lowerName containsString:@"switch"] ||
        [lowerName containsString:@"pro controller"]) {
        return YES;
    }

    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    if (!manufacturerData || manufacturerData.length < 2) {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)manufacturerData.bytes;
    uint16_t companyID = bytes[0] | (bytes[1] << 8);
    if (companyID == NINTENDO_MANUFACTURER_ID) {
        return YES;
    }

    // Switch2-Controllers matches the Switch 2 controller payload marker
    // 03 7E inside the manufacturer payload, independent of the BLE company key.
    if (manufacturerData.length >= 4 && bytes[2] == 0x03 && bytes[3] == 0x7E) {
        return YES;
    }
    if (manufacturerData.length >= 6 && bytes[4] == 0x03 && bytes[5] == 0x7E) {
        return YES;
    }

    return NO;
}

- (JoyConSide)sideForPeripheralName:(NSString *)name {
    NSString *lowerName = [[name ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lowerName containsString:@"right"] ||
        [lowerName containsString:@"joy-con (r"] ||
        [lowerName containsString:@"joy-con 2 (r"] ||
        [lowerName containsString:@"(r)"] ||
        [lowerName hasSuffix:@" r"] ||
        [lowerName hasSuffix:@"-r"]) {
        return JoyConSide::Right;
    }
    return JoyConSide::Left;
}

- (NSNumber *)explicitSideForPeripheralName:(NSString *)name {
    NSString *lowerName = [[name ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lowerName containsString:@"right"] ||
        [lowerName containsString:@"joy-con (r"] ||
        [lowerName containsString:@"joy-con 2 (r"] ||
        [lowerName containsString:@"(r)"] ||
        [lowerName hasSuffix:@" r"] ||
        [lowerName hasSuffix:@"-r"]) {
        return @((NSInteger)JoyConSide::Right);
    }
    if ([lowerName containsString:@"left"] ||
        [lowerName containsString:@"joy-con (l"] ||
        [lowerName containsString:@"joy-con 2 (l"] ||
        [lowerName containsString:@"(l)"] ||
        [lowerName hasSuffix:@" l"] ||
        [lowerName hasSuffix:@"-l"]) {
        return @((NSInteger)JoyConSide::Left);
    }
    return nil;
}

- (JoyConSide)missingOrDefaultSide {
    if (![self hasContextForSide:JoyConSide::Left] && ![self hasPendingConnectionForSide:JoyConSide::Left]) {
        return JoyConSide::Left;
    }
    return JoyConSide::Right;
}

- (BOOL)hasContextForSide:(JoyConSide)side {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.side == side &&
            context.peripheral.state != CBPeripheralStateDisconnected) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasPendingConnectionForSide:(JoyConSide)side {
    for (NSString *peripheralID in _connectingPeripheralIDs) {
        NSNumber *sideValue = _sideByPeripheralID[peripheralID];
        if (sideValue && (JoyConSide)sideValue.integerValue == side) {
            return YES;
        }
    }
    for (NSString *peripheralID in _pendingPeripheralsByID.allKeys) {
        NSNumber *sideValue = _sideByPeripheralID[peripheralID];
        if (sideValue && (JoyConSide)sideValue.integerValue == side) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasBothSides {
    return [self hasContextForSide:JoyConSide::Left] && [self hasContextForSide:JoyConSide::Right];
}

- (NSUInteger)activeOrPendingConnectionCount {
    NSUInteger count = _connectingPeripheralIDs.count;
    count += _pendingPeripheralsByID.count;
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.peripheral.state != CBPeripheralStateDisconnected) {
            count++;
        }
    }
    return count;
}

- (void)beginConnectionToPeripheral:(CBPeripheral *)peripheral
                               side:(JoyConSide)side
                               name:(NSString *)deviceName
                               RSSI:(NSNumber *)RSSI
                    sideWasInferred:(BOOL)sideWasInferred {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    NSNumber *attemptValue = _reconnectAttemptsByPeripheralID[peripheralID] ?: @0;

    _sideByPeripheralID[peripheralID] = @((NSInteger)side);
    _lastConnectionAttemptByPeripheralID[peripheralID] = [NSDate date];
    _reconnectAttemptsByPeripheralID[peripheralID] = @(attemptValue.integerValue + 1);
    [_connectingPeripheralIDs addObject:peripheralID];

    std::cout << "[BLE] Connecting to " << [[self labelForSide:side] UTF8String]
              << " Joy-Con: " << [deviceName UTF8String]
              << (sideWasInferred ? " (side inferred)" : "")
              << " [RSSI: " << [RSSI intValue] << " dBm]" << std::endl;
    [self emitTelemetry:"connect.begin"
                 detail:[NSString stringWithFormat:@"name=%@ rssi=%@ sideInferred=%@ attempt=%ld",
                         deviceName, RSSI, sideWasInferred ? @"true" : @"false", (long)attemptValue.integerValue + 1]
                   side:side
                   name:deviceName];
    [self emitStatus:"connecting" message:"BLE peripheral found" side:side name:deviceName];
    [self.centralManager connectPeripheral:peripheral options:nil];
}

- (void)connectNextPendingPeripheralIfPossible {
    NSUInteger activeCount = 0;
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        if (context.peripheral.state != CBPeripheralStateDisconnected) {
            activeCount++;
        }
    }
    if (_connectingPeripheralIDs.count > 0 || activeCount >= 2) {
        return;
    }

    for (NSString *peripheralID in _pendingPeripheralsByID.allKeys) {
        CBPeripheral *peripheral = _pendingPeripheralsByID[peripheralID];
        NSNumber *sideValue = _sideByPeripheralID[peripheralID];
        if (!peripheral || !sideValue) {
            [_pendingPeripheralsByID removeObjectForKey:peripheralID];
            [_pendingNamesByID removeObjectForKey:peripheralID];
            [_pendingRSSIByID removeObjectForKey:peripheralID];
            [_pendingSideWasInferredByID removeObjectForKey:peripheralID];
            continue;
        }

        JoyConSide side = (JoyConSide)sideValue.integerValue;
        if ([self hasContextForSide:side]) {
            [_pendingPeripheralsByID removeObjectForKey:peripheralID];
            [_pendingNamesByID removeObjectForKey:peripheralID];
            [_pendingRSSIByID removeObjectForKey:peripheralID];
            [_pendingSideWasInferredByID removeObjectForKey:peripheralID];
            continue;
        }

        NSString *deviceName = _pendingNamesByID[peripheralID] ?: peripheral.name ?: @"Unknown";
        NSNumber *RSSI = _pendingRSSIByID[peripheralID] ?: @0;
        BOOL sideWasInferred = _pendingSideWasInferredByID[peripheralID].boolValue;

        [_pendingPeripheralsByID removeObjectForKey:peripheralID];
        [_pendingNamesByID removeObjectForKey:peripheralID];
        [_pendingRSSIByID removeObjectForKey:peripheralID];
        [_pendingSideWasInferredByID removeObjectForKey:peripheralID];

        [self beginConnectionToPeripheral:peripheral
                                     side:side
                                     name:deviceName
                                     RSSI:RSSI
                          sideWasInferred:sideWasInferred];
        return;
    }
}

- (JoyConPeripheralContext *)contextForPeripheral:(CBPeripheral *)peripheral {
    return _contextsByPeripheralID[[self keyForPeripheral:peripheral]];
}

- (NSString *)keyForContext:(JoyConPeripheralContext *)context {
    if (!context || !context.peripheral) {
        return nil;
    }
    return [self keyForPeripheral:context.peripheral];
}

- (void)queueInitializationForContext:(JoyConPeripheralContext *)context reason:(NSString *)reason {
    NSString *peripheralID = [self keyForContext:context];
    if (!peripheralID) {
        return;
    }
    if (![_pendingInitializationPeripheralIDs containsObject:peripheralID]) {
        [_pendingInitializationPeripheralIDs addObject:peripheralID];
    }
    [self emitTelemetry:"init.queued"
                 detail:reason ?: @"another startup sequence is active"
             forContext:context];
    [self emitStatus:"queued" message:"Waiting for other Joy-Con startup commands" forContext:context];
}

- (void)startNextQueuedInitializationIfPossible {
    if (_startupOwnerPeripheralID != nil) {
        return;
    }

    while (_pendingInitializationPeripheralIDs.count > 0) {
        NSString *peripheralID = _pendingInitializationPeripheralIDs.firstObject;
        [_pendingInitializationPeripheralIDs removeObjectAtIndex:0];

        JoyConPeripheralContext *context = _contextsByPeripheralID[peripheralID];
        if (!context ||
            context.peripheral.state != CBPeripheralStateConnected ||
            !context.characteristicsReady ||
            context.initStarted ||
            context.isInitialized) {
            continue;
        }

        [self initializeIMUForContext:context];
        return;
    }
}

- (void)releaseStartupSlotForContext:(JoyConPeripheralContext *)context {
    NSString *peripheralID = [self keyForContext:context];
    if (!peripheralID || ![_startupOwnerPeripheralID isEqualToString:peripheralID]) {
        return;
    }

    _startupOwnerPeripheralID = nil;
    [self emitTelemetry:"init.slotReleased"
                 detail:@"startup command slot released"
             forContext:context];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self connectNextPendingPeripheralIfPossible];
        [self startNextQueuedInitializationIfPossible];
    });
}

- (JoyConPeripheralContext *)contextForCharacteristic:(CBCharacteristic *)characteristic peripheral:(CBPeripheral *)peripheral {
    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (!context) {
        return nil;
    }
    if ([characteristic isEqual:context.inputCharacteristic] ||
        [characteristic isEqual:context.responseCharacteristic] ||
        [characteristic isEqual:context.commandCharacteristic]) {
        return context;
    }
    return nil;
}

#pragma mark - Command Sending

- (void)sendCommand:(NSData *)commandData {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self enqueueCommand:commandData label:@"manual command" toContext:context];
    }
}

- (void)sendCommand:(NSData *)commandData toContext:(JoyConPeripheralContext *)context {
    [self enqueueCommand:commandData label:@"manual command" toContext:context];
}

- (void)enqueueCommand:(NSData *)commandData label:(NSString *)label toContext:(JoyConPeripheralContext *)context {
    [self enqueueCommand:commandData label:label waitsForProtocolResponse:YES toContext:context];
}

- (void)enqueueCommand:(NSData *)commandData
                 label:(NSString *)label
waitsForProtocolResponse:(BOOL)waitsForProtocolResponse
             toContext:(JoyConPeripheralContext *)context {
    if (!commandData || !context) {
        return;
    }
    [context.commandQueue addObject:commandData];
    [context.commandLabels addObject:label ?: @"command"];
    [context.commandWaitsForProtocolResponse addObject:@(waitsForProtocolResponse)];
    [self emitTelemetry:"command.enqueue"
                 detail:[NSString stringWithFormat:@"label=%@ waitsForProtocolResponse=%@ queueDepth=%lu bytes=%@",
                         label ?: @"command",
                         waitsForProtocolResponse ? @"true" : @"false",
                         (unsigned long)context.commandQueue.count,
                         [self hexStringForData:commandData maxBytes:24]]
             forContext:context];
    [self sendNextQueuedCommandForContext:context];
}

- (void)sendNextQueuedCommandForContext:(JoyConPeripheralContext *)context {
    if (context.commandInFlight || context.commandQueue.count == 0) {
        if (!context.commandInFlight && context.initStarted && !context.isInitialized && context.commandQueue.count == 0) {
            context.isInitialized = YES;
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
                      << " startup command sequence complete" << std::endl;
            [self emitTelemetry:"init.ready" detail:@"startup command queue drained" forContext:context];
            if (!context.pairingPersistenceStarted) {
                context.pairingPersistenceStarted = YES;
                [self sendPairingPersistenceCommandsToContext:context];
            }
            // Emit exactly one confirmation: flip the LED to final pattern.
            // Removing the duplicate "connected vibration confirm" pulse —
            // Joy2Win already got a vibration inside initializeIMUForContext,
            // so doing a second one here makes the controllers buzz twice.
            [self setPlayerLED:context.ledMask forContext:context label:@"set player LED final"];
            if (context.commandQueue.count == 0 && !context.commandInFlight) {
                [self sendNextQueuedCommandForContext:context];
            }
        } else if (!context.commandInFlight &&
                   context.initStarted &&
                   context.isInitialized &&
                   !context.startupLifecycleDone &&
                   context.commandQueue.count == 0) {
            context.startupLifecycleDone = YES;
            [self emitTelemetry:"init.lifecycleReady"
                         detail:@"pairing persistence and confirmation commands complete"
                     forContext:context];
            [self emitStatus:"ready" message:"Device ready" forContext:context];
            [self releaseStartupSlotForContext:context];
        }
        return;
    }

    NSData *commandData = context.commandQueue.firstObject;
    NSString *label = context.commandLabels.firstObject;
    BOOL waitsForProtocolResponse = context.commandWaitsForProtocolResponse.firstObject.boolValue;
    [context.commandQueue removeObjectAtIndex:0];
    [context.commandLabels removeObjectAtIndex:0];
    [context.commandWaitsForProtocolResponse removeObjectAtIndex:0];

    if (!context.commandCharacteristic || !context.peripheral) {
        std::cout << "[BLE] Error: Command characteristic not available" << std::endl;
        context.commandInFlight = NO;
        [self sendNextQueuedCommandForContext:context];
        return;
    }

    const uint8_t *bytes = (const uint8_t *)commandData.bytes;
    context.commandInFlight = YES;
    context.waitingForResponse = waitsForProtocolResponse;
    context.currentCommandWaitsForProtocolResponse = waitsForProtocolResponse;
    context.currentCommandID = commandData.length > 0 ? bytes[0] : 0;

    std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
              << " " << [label UTF8String] << ": ";
    for (NSUInteger i = 0; i < commandData.length; i++) {
        printf("%02X ", bytes[i]);
    }
    std::cout << std::endl;
    [self emitTelemetry:"command.write"
                 detail:[NSString stringWithFormat:@"label=%@ waitsForProtocolResponse=%@ remainingQueue=%lu bytes=%@",
                         label ?: @"command",
                         waitsForProtocolResponse ? @"true" : @"false",
                         (unsigned long)context.commandQueue.count,
                         [self hexStringForData:commandData maxBytes:24]]
             forContext:context];

    CBCharacteristicWriteType writeType = CBCharacteristicWriteWithResponse;
    if (!(context.commandCharacteristic.properties & CBCharacteristicPropertyWrite) &&
        (context.commandCharacteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)) {
        writeType = CBCharacteristicWriteWithoutResponse;
    }

    [self emitTelemetry:"command.writeMode"
                 detail:[NSString stringWithFormat:@"label=%@ mode=%@ properties=%@",
                         label ?: @"command",
                         writeType == CBCharacteristicWriteWithResponse ? @"withResponse" : @"withoutResponse",
                         [self propertiesStringForCharacteristic:context.commandCharacteristic]]
             forContext:context];

    [context.peripheral writeValue:commandData
                  forCharacteristic:context.commandCharacteristic
                               type:writeType];
    if (writeType == CBCharacteristicWriteWithoutResponse && !waitsForProtocolResponse) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeQueuedCommandForContext:context];
        });
        return;
    }
    if (waitsForProtocolResponse) {
        [self scheduleCommandTimeoutForContext:context label:label];
    }
}

- (void)scheduleCommandTimeoutForContext:(JoyConPeripheralContext *)context label:(NSString *)label {
    [context.responseTimer invalidate];
    context.responseTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            repeats:NO
                                                              block:^(NSTimer * _Nonnull timer) {
        if (!context.waitingForResponse) {
            return;
        }
        std::cout << "[BLE] Warning: No response for "
                  << [[self labelForSide:context.side] UTF8String]
                  << " " << [label UTF8String] << ", continuing" << std::endl;
        [self emitTelemetry:"command.timeout"
                     detail:[NSString stringWithFormat:@"label=%@", label ?: @"command"]
                 forContext:context];
        [self emitStatus:"commandTimeout" message:[label UTF8String] forContext:context];
        context.waitingForResponse = NO;
        context.commandInFlight = NO;
        context.currentCommandID = 0;
        [self sendNextQueuedCommandForContext:context];
    }];
}

- (void)completeQueuedCommandForContext:(JoyConPeripheralContext *)context {
    context.waitingForResponse = NO;
    context.commandInFlight = NO;
    context.currentCommandID = 0;
    [context.responseTimer invalidate];
    context.responseTimer = nil;
    [self emitTelemetry:"command.complete" detail:@"command completed" forContext:context];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self sendNextQueuedCommandForContext:context];
    });
}

- (void)initializeIMU {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self initializeIMUForContext:context];
    }
}

- (void)initializeIMUForContext:(JoyConPeripheralContext *)context {
    if (context.initStarted || context.isInitialized) {
        return;
    }

    NSString *peripheralID = [self keyForContext:context];
    if (_startupOwnerPeripheralID != nil && ![_startupOwnerPeripheralID isEqualToString:peripheralID]) {
        [self queueInitializationForContext:context reason:@"another Joy-Con is still running startup commands"];
        return;
    }
    _startupOwnerPeripheralID = peripheralID;

    context.initStarted = YES;
    std::cout << "[BLE] Starting startup command sequence for "
              << [[self labelForSide:context.side] UTF8String]
              << " Joy-Con..." << std::endl;
    [self emitTelemetry:"init.start" detail:@"queueing vibration, LED, sensor init, sensor finalize, sensor start" forContext:context];
    [self emitStatus:"initializing" message:"Sending startup commands" forContext:context];

    [self sendPairingVibrationToContext:context];
    [self setPlayerLED:context.ledMask forContext:context];
    // IMU enable sequence per joycon2cpp's SendCustomCommands: only subCmd 0x02
    // and 0x04 are sent (not 0x03), using WriteWithoutResponse (no ACK expected).
    // Passing waitsForProtocolResponse:NO stops the queue from stalling on a
    // response that never arrives, which is why gyro/accel were stuck at 0.
    [self enqueueCommand:[self dataFromHexString:@"0C91010200040000FF000000"]
                   label:@"imu enable step1 (0x02)"
waitsForProtocolResponse:NO
               toContext:context];
    [self enqueueCommand:[self dataFromHexString:@"0C91010400040000FF000000"]
                   label:@"imu enable step2 (0x04)"
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)scheduleResponseTimeoutForContext:(JoyConPeripheralContext *)context step:(int)step {
    [context.responseTimer invalidate];
    context.responseTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                            repeats:NO
                                                              block:^(NSTimer * _Nonnull timer) {
        if (!context.waitingForResponse) {
            return;
        }
        std::cout << "[BLE] Warning: No response for "
                  << [[self labelForSide:context.side] UTF8String]
                  << " IMU step " << step << ", continuing" << std::endl;
        context.waitingForResponse = NO;
        context.commandInFlight = NO;
        [self sendNextQueuedCommandForContext:context];
    }];
}

- (void)setPlayerLED:(uint8_t)ledMask {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self setPlayerLED:ledMask forContext:context];
    }
}

- (void)setPlayerLED:(uint8_t)ledMask forContext:(JoyConPeripheralContext *)context {
    [self setPlayerLED:ledMask forContext:context label:@"set player LED"];
}

- (void)setPlayerLED:(uint8_t)ledMask forContext:(JoyConPeripheralContext *)context label:(NSString *)label {
    uint8_t cmdBytes[] = {0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
                          ledMask, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    NSData *commandData = [NSData dataWithBytes:cmdBytes length:sizeof(cmdBytes)];
    [self enqueueCommand:commandData
                   label:label ?: @"set player LED"
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)setPlayerLEDFallback:(uint8_t)ledMask forContext:(JoyConPeripheralContext *)context {
    uint8_t cmdBytes[] = {0x30, 0x01, 0x00, 0x30, 0x00, 0x08, 0x00, 0x00,
                          ledMask, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    NSData *commandData = [NSData dataWithBytes:cmdBytes length:sizeof(cmdBytes)];
    [self enqueueCommand:commandData
                   label:@"set player LED fallback"
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)sendPairingVibration {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self sendPairingVibrationToContext:context];
    }
}

- (void)sendPairingVibrationToContext:(JoyConPeripheralContext *)context {
    [self sendPairingVibrationToContext:context label:@"connected vibration"];
}

- (void)sendPairingVibrationToContext:(JoyConPeripheralContext *)context label:(NSString *)label {
    [self enqueueCommand:[self dataFromHexString:@"0A9101020004000003000000"]
                   label:label ?: @"connected vibration"
waitsForProtocolResponse:NO
               toContext:context];
}

- (void)sendPairingPersistenceCommands {
    for (JoyConPeripheralContext *context in _contextsByPeripheralID.allValues) {
        [self sendPairingPersistenceCommandsToContext:context];
    }
}

- (void)sendPairingPersistenceCommandsToContext:(JoyConPeripheralContext *)context {
    PairingManager *pairingManager = [PairingManager sharedManager];
    NSString *localMAC = [pairingManager getLocalBluetoothAddress];
    if (!localMAC) {
        std::cout << "[BLE] Skipping MAC persistence: local Bluetooth MAC unavailable" << std::endl;
        [self emitTelemetry:"pairing.skip" detail:@"local Bluetooth MAC unavailable" forContext:context];
        return;
    }

    [self emitTelemetry:"pairing.start"
                 detail:[NSString stringWithFormat:@"localMAC=%@", localMAC]
             forContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep1:localMAC mac2:nil] label:@"save MAC step 1" toContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep2] label:@"save MAC step 2" toContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep3] label:@"save MAC step 3" toContext:context];
    [self enqueueCommand:[pairingManager generateMACBindingStep4] label:@"save MAC step 4" toContext:context];
}

- (NSData *)dataFromHexString:(NSString *)hexString {
    NSMutableData *data = [NSMutableData data];
    unsigned char byte;
    for (NSUInteger i = 0; i < hexString.length; i += 2) {
        NSString *byteString = [hexString substringWithRange:NSMakeRange(i, 2)];
        byte = (unsigned char)strtol([byteString UTF8String], NULL, 16);
        [data appendBytes:&byte length:1];
    }
    return data;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            std::cout << "[BLE] Bluetooth powered on" << std::endl;
            [self emitTelemetry:"central.poweredOn" detail:@"CoreBluetooth ready" side:JoyConSide::Left name:nil];
            [self startScanning];
            break;
        case CBManagerStatePoweredOff:
            std::cout << "[BLE] Bluetooth powered off" << std::endl;
            [self emitTelemetry:"central.poweredOff" detail:@"Bluetooth is off" side:JoyConSide::Left name:nil];
            break;
        case CBManagerStateUnsupported:
            std::cout << "[BLE] Bluetooth not supported" << std::endl;
            [self emitTelemetry:"central.unsupported" detail:@"Bluetooth unsupported" side:JoyConSide::Left name:nil];
            break;
        case CBManagerStateUnauthorized:
            std::cout << "[BLE] Bluetooth unauthorized" << std::endl;
            [self emitTelemetry:"central.unauthorized" detail:@"Bluetooth permission denied" side:JoyConSide::Left name:nil];
            break;
        default:
            std::cout << "[BLE] Bluetooth state: " << (int)central.state << std::endl;
            [self emitTelemetry:"central.state"
                         detail:[NSString stringWithFormat:@"state=%ld", (long)central.state]
                           side:JoyConSide::Left
                           name:nil];
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (![self isNintendoAdvertisement:advertisementData peripheral:peripheral]) {
        return;
    }

    NSString *peripheralID = [self keyForPeripheral:peripheral];
    if (_contextsByPeripheralID[peripheralID] ||
        [_connectingPeripheralIDs containsObject:peripheralID] ||
        _pendingPeripheralsByID[peripheralID]) {
        return;
    }

    if ([self activeOrPendingConnectionCount] >= 2) {
        return;
    }

    NSString *deviceName = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"Unknown";
    NSNumber *explicitSide = [self explicitSideForPeripheralName:deviceName];
    BOOL sideWasInferred = (explicitSide == nil);
    JoyConSide side = explicitSide ? (JoyConSide)explicitSide.integerValue : [self missingOrDefaultSide];
    NSData *manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey];
    NSString *manufacturerHex = [self hexStringForData:manufacturerData maxBytes:32];

    [self emitTelemetry:"scan.candidate"
                 detail:[NSString stringWithFormat:@"name=%@ rssi=%@ manufacturer=%@ side=%@ inferred=%@",
                         deviceName,
                         RSSI,
                         manufacturerHex,
                         [self labelForSide:side],
                         sideWasInferred ? @"true" : @"false"]
                   side:side
                   name:deviceName];

    if (explicitSide && ([self hasContextForSide:side] || [self hasPendingConnectionForSide:side])) {
        std::cout << "[BLE] Ignoring additional " << [[self labelForSide:side] UTF8String]
                  << " Joy-Con candidate: " << [deviceName UTF8String] << std::endl;
        [self emitTelemetry:"scan.ignored"
                     detail:@"same side already active or pending"
                       side:side
                       name:deviceName];
        return;
    }

    NSDate *lastAttempt = _lastConnectionAttemptByPeripheralID[peripheralID];
    NSNumber *attemptValue = _reconnectAttemptsByPeripheralID[peripheralID] ?: @0;
    if (lastAttempt && attemptValue.integerValue > 0) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:lastAttempt];
        if (elapsed < 180.0) {
            std::cout << "[BLE] Cooldown active for " << [deviceName UTF8String]
                      << ". Waiting " << (int)(180.0 - elapsed) << " more seconds" << std::endl;
            [self emitTelemetry:"scan.cooldown"
                         detail:[NSString stringWithFormat:@"remainingSeconds=%.0f", 180.0 - elapsed]
                           side:side
                           name:deviceName];
            return;
        }
    }

    if (![self.discoveredPeripherals containsObject:peripheral]) {
        [self.discoveredPeripherals addObject:peripheral];
    }

    if (_connectingPeripheralIDs.count > 0) {
        _sideByPeripheralID[peripheralID] = @((NSInteger)side);
        _pendingPeripheralsByID[peripheralID] = peripheral;
        _pendingNamesByID[peripheralID] = deviceName;
        _pendingRSSIByID[peripheralID] = RSSI;
        _pendingSideWasInferredByID[peripheralID] = @(sideWasInferred);
        std::cout << "[BLE] Queued " << [[self labelForSide:side] UTF8String]
                  << " Joy-Con: " << [deviceName UTF8String] << std::endl;
        [self emitTelemetry:"connect.queued"
                     detail:@"another BLE connection is in progress"
                       side:side
                       name:deviceName];
        [self emitStatus:"queued" message:"Waiting for current BLE connection" side:side name:deviceName];
        return;
    }

    [self beginConnectionToPeripheral:peripheral
                                 side:side
                                 name:deviceName
                                 RSSI:RSSI
                      sideWasInferred:sideWasInferred];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    JoyConSide side = (JoyConSide)(_sideByPeripheralID[peripheralID] ?: @((NSInteger)JoyConSide::Left)).integerValue;

    JoyConPeripheralContext *context = [[JoyConPeripheralContext alloc] init];
    context.peripheral = peripheral;
    context.side = side;
    context.sideWasInferred = ([self explicitSideForPeripheralName:peripheral.name] == nil);
    context.ledMask = side == JoyConSide::Left ? 0x01 : 0x02;
    _contextsByPeripheralID[peripheralID] = context;
    [_connectingPeripheralIDs removeObject:peripheralID];
    _reconnectAttemptsByPeripheralID[peripheralID] = @0;

    std::cout << "[BLE] Connected " << [[self labelForSide:side] UTF8String] << " Joy-Con. Discovering services..." << std::endl;
    [self emitTelemetry:"connect.connected" detail:@"CoreBluetooth didConnectPeripheral" forContext:context];
    [self emitStatus:"bleConnected" message:"Discovering services" forContext:context];
    peripheral.delegate = self;
    [peripheral discoverServices:nil];

    if ([self hasBothSides]) {
        [self stopScanning];
    } else {
        [self connectNextPendingPeripheralIfPossible];
    }
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    [_connectingPeripheralIDs removeObject:peripheralID];
    std::cout << "[BLE] Failed to connect: " << [[error localizedDescription] UTF8String] << std::endl;
    NSNumber *sideValue = _sideByPeripheralID[peripheralID];
    JoyConSide side = sideValue ? (JoyConSide)sideValue.integerValue : JoyConSide::Left;
    [self emitTelemetry:"connect.failed"
                 detail:error.localizedDescription ?: @"Connection failed"
                   side:side
                   name:peripheral.name];
    [self emitStatus:"connectFailed"
             message:error.localizedDescription ? [error.localizedDescription UTF8String] : "Connection failed"
                side:side
                name:peripheral.name];

    NSNumber *attemptValue = _reconnectAttemptsByPeripheralID[peripheralID] ?: @1;
    NSTimeInterval backoff = pow(2, MIN((int)attemptValue.integerValue, 5)) * 30.0;
    std::cout << "[BLE] Will retry scan in " << (int)backoff << " seconds" << std::endl;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self connectNextPendingPeripheralIfPossible];
        [self startScanning];
    });
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    NSString *peripheralID = [self keyForPeripheral:peripheral];
    JoyConPeripheralContext *context = _contextsByPeripheralID[peripheralID];
    if (context) {
        std::cout << "[BLE] Disconnected " << [[self labelForSide:context.side] UTF8String] << " Joy-Con" << std::endl;
        [self emitTelemetry:"connect.disconnected"
                     detail:error.localizedDescription ?: @"Disconnected"
                 forContext:context];
        [self emitStatus:"disconnected"
                 message:error.localizedDescription ? [error.localizedDescription UTF8String] : "Disconnected"
              forContext:context];
        [context.responseTimer invalidate];
    } else {
        std::cout << "[BLE] Disconnected Joy-Con" << std::endl;
    }

    [_contextsByPeripheralID removeObjectForKey:peripheralID];
    [_connectingPeripheralIDs removeObject:peripheralID];
    [_pendingInitializationPeripheralIDs removeObject:peripheralID];
    if ([_startupOwnerPeripheralID isEqualToString:peripheralID]) {
        _startupOwnerPeripheralID = nil;
        [self startNextQueuedInitializationIfPossible];
    }

    if (!_isShuttingDown) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [self connectNextPendingPeripheralIfPossible];
            [self startScanning];
        });
    }
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        std::cout << "[BLE] Error discovering services: " << [[error localizedDescription] UTF8String] << std::endl;
        JoyConPeripheralContext *failedContext = [self contextForPeripheral:peripheral];
        if (failedContext) {
            [self emitTelemetry:"services.failed" detail:error.localizedDescription ?: @"service discovery failed" forContext:failedContext];
        }
        return;
    }

    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (!context) {
        return;
    }
    std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
              << " discovered " << peripheral.services.count << " services" << std::endl;
    NSMutableArray<NSString *> *serviceUUIDs = [NSMutableArray array];
    for (CBService *service in peripheral.services) {
        [serviceUUIDs addObject:service.UUID.UUIDString];
        [peripheral discoverCharacteristics:nil forService:service];
    }
    [self emitTelemetry:"services.discovered"
                 detail:[NSString stringWithFormat:@"count=%lu uuids=%@",
                         (unsigned long)peripheral.services.count,
                         [serviceUUIDs componentsJoinedByString:@","]]
             forContext:context];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (error) {
        return;
    }

    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (!context) {
        return;
    }

    CBUUID *inputUUID = [CBUUID UUIDWithString:UUID_INPUT];
    CBUUID *commandUUID = [CBUUID UUIDWithString:UUID_COMMAND];
    CBUUID *responseUUID = [CBUUID UUIDWithString:UUID_RESPONSE];

    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:inputUUID]) {
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String] << " input characteristic" << std::endl;
            context.inputCharacteristic = characteristic;
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            [self emitTelemetry:"characteristic.input"
                         detail:[NSString stringWithFormat:@"uuid=%@ properties=%@ notify=true",
                                 characteristic.UUID.UUIDString,
                                 [self propertiesStringForCharacteristic:characteristic]]
                     forContext:context];
        } else if ([characteristic.UUID isEqual:commandUUID]) {
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String] << " command characteristic" << std::endl;
            context.commandCharacteristic = characteristic;
            [self emitTelemetry:"characteristic.command"
                         detail:[NSString stringWithFormat:@"uuid=%@ properties=%@",
                                 characteristic.UUID.UUIDString,
                                 [self propertiesStringForCharacteristic:characteristic]]
                     forContext:context];
        } else if ([characteristic.UUID isEqual:responseUUID]) {
            std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String] << " response characteristic" << std::endl;
            context.responseCharacteristic = characteristic;
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
            [self emitTelemetry:"characteristic.response"
                         detail:[NSString stringWithFormat:@"uuid=%@ properties=%@ notify=true",
                                 characteristic.UUID.UUIDString,
                                 [self propertiesStringForCharacteristic:characteristic]]
                     forContext:context];
        }
    }

    if (context.inputCharacteristic &&
        context.commandCharacteristic &&
        context.responseCharacteristic &&
        !context.characteristicsReady) {
        context.characteristicsReady = YES;
        [self emitTelemetry:"services.ready"
                     detail:@"input, command, and response characteristics discovered"
                 forContext:context];
        [self emitStatus:"servicesReady" message:"Nintendo characteristics discovered" forContext:context];
        NSString *peripheralID = [[self keyForPeripheral:peripheral] copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            JoyConPeripheralContext *readyContext = self->_contextsByPeripheralID[peripheralID];
            if (!readyContext || readyContext.peripheral.state != CBPeripheralStateConnected) {
                return;
            }
            [self initializeIMUForContext:readyContext];
        });
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) {
        return;
    }

    JoyConPeripheralContext *context = [self contextForCharacteristic:characteristic peripheral:peripheral];
    if (!context) {
        return;
    }

    NSData *data = characteristic.value;
    if ([characteristic isEqual:context.responseCharacteristic]) {
        std::cout << "[BLE] " << [[self labelForSide:context.side] UTF8String]
                  << " command response (" << data.length << " bytes)" << std::endl;
        [self emitTelemetry:"command.response"
                     detail:[NSString stringWithFormat:@"length=%lu bytes=%@",
                             (unsigned long)data.length,
                             [self hexStringForData:data maxBytes:24]]
                 forContext:context];
        if (context.waitingForResponse) {
            const uint8_t *responseBytes = (const uint8_t *)data.bytes;
            if (data.length > 0 && responseBytes[0] != context.currentCommandID) {
                [self emitTelemetry:"command.responseIgnored"
                             detail:[NSString stringWithFormat:@"expectedCommand=%02X got=%02X",
                                     context.currentCommandID,
                                     responseBytes[0]]
                         forContext:context];
                return;
            }
            [self completeQueuedCommandForContext:context];
        }
        return;
    }

    if ([characteristic isEqual:context.inputCharacteristic]) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        std::vector<uint8_t> buffer(bytes, bytes + data.length);
        if (_dataCallback) {
            _dataCallback(buffer, context.side);
        }
        context.inputPacketCount += 1;
        if (context.inputPacketCount <= 5 || context.inputPacketCount % 600 == 0) {
            [self emitTelemetry:"input.packet"
                         detail:[NSString stringWithFormat:@"count=%lu length=%lu",
                                 (unsigned long)context.inputPacketCount,
                                 (unsigned long)data.length]
                     forContext:context];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    JoyConPeripheralContext *context = [self contextForPeripheral:peripheral];
    if (error) {
        NSString *sideLabel = context ? [self labelForSide:context.side] : @"Unknown";
        std::cout << "[BLE] Error writing " << [sideLabel UTF8String]
                  << " characteristic: " << [[error localizedDescription] UTF8String] << std::endl;
        if (context) {
            [self emitTelemetry:"command.writeFailed"
                         detail:error.localizedDescription ?: @"GATT write failed"
                     forContext:context];
            [self emitStatus:"writeFailed"
                     message:error.localizedDescription ? [error.localizedDescription UTF8String] : "GATT write failed"
                  forContext:context];
            context.waitingForResponse = NO;
            context.commandInFlight = NO;
            context.currentCommandID = 0;
            [context.responseTimer invalidate];
            context.responseTimer = nil;
            [self sendNextQueuedCommandForContext:context];
        }
        return;
    }

    if (context && context.commandInFlight && !context.currentCommandWaitsForProtocolResponse) {
        [self emitTelemetry:"command.writeAck" detail:@"CoreBluetooth write-with-response completed" forContext:context];
        [self completeQueuedCommandForContext:context];
    }
}

@end
