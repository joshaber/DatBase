//
//  DABTransactor.m
//  DatBase
//
//  Created by Josh Abernathy on 10/9/13.
//  Copyright (c) 2013 Josh Abernathy. All rights reserved.
//

#import "DABTransactor.h"
#import "DABDatabase+Private.h"
#import "DABCoordinator.h"
#import "DABCoordinator+Private.h"
#import "FMDatabase.h"

@interface DABTransactor ()

@property (nonatomic, readonly, strong) DABCoordinator *coordinator;

@end

@implementation DABTransactor

- (id)initWithCoordinator:(DABCoordinator *)coordinator {
	NSParameterAssert(coordinator != nil);

	self = [super init];
	if (self == nil) return nil;

	_coordinator = coordinator;

	return self;
}

- (NSString *)generateNewKey {
	// Problem?
	return [[NSUUID UUID] UUIDString];
}

- (BOOL)addValue:(id)value forAttribute:(NSString *)attribute key:(NSString *)key error:(NSError **)error {
	NSParameterAssert(value != nil);
	NSParameterAssert(attribute != nil);
	NSParameterAssert(key != nil);

	NSDate *date = [NSDate date];
	NSData *valueData = [NSKeyedArchiver archivedDataWithRootObject:value];

	// We could split some of this work out into a non-exclusive transaction,
	// but by batching it all in a single transaction we get a much higher write
	// speed. (~370 w/s vs. ~600 w/s on my computer).
	//
	// TODO: Test whether the write cost of splitting it up is made up in read
	// speed.
	return [self.coordinator performTransactionType:DABCoordinatorTransactionTypeExclusive error:error block:^(FMDatabase *database, NSError **error) {
		long long int headID = [self.coordinator headID:NULL];

		NSString *txKey = [self generateNewKey];
		BOOL success = [database executeUpdate:@"INSERT INTO entities (attribute, value, key, tx_id) VALUES (?, ?, ?, ?)", @"date", date, txKey, @(headID)];
		if (!success) {
			if (error != NULL) *error = database.lastError;
			return NO;
		}

		sqlite_int64 txID = database.lastInsertRowId;

		success = [database executeUpdate:@"INSERT INTO entities (attribute, value, key, tx_id) VALUES (?, ?, ?, ?)", attribute, valueData, key, @(txID)];
		if (!success) {
			if (error != NULL) *error = database.lastError;
			return NO;
		}

		FMResultSet *set = [database executeQuery:@"SELECT id FROM entities WHERE key = ? LIMIT 1", @"head"];
		NSData *txIDData = [NSKeyedArchiver archivedDataWithRootObject:@(txID)];
		if (![set next]) {
			success = [database executeUpdate:@"INSERT INTO entities (attribute, value, key, tx_id) VALUES (?, ?, ?, ?)", @"id", txIDData, @"head", @0];
		} else {
			success = [database executeUpdate:@"UPDATE entities SET value = ? WHERE key = ?", txIDData, @"head"];
		}

		if (!success) {
			if (error != NULL) *error = database.lastError;
			return NO;
		}

		return YES;
	}];
}

@end
