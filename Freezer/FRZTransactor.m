//
//  FRZTransactor.m
//  Freezer
//
//  Created by Josh Abernathy on 10/9/13.
//  Copyright (c) 2013 Josh Abernathy. All rights reserved.
//

#import "FRZTransactor.h"
#import "FRZDatabase+Private.h"
#import "FRZStore.h"
#import "FRZStore+Private.h"
#import "FMDatabase.h"
#import "FRZChange+Private.h"
#import "FRZSingleIDTransactor+Private.h"

@interface FRZTransactor ()

@property (nonatomic, readonly, strong) FRZStore *store;

@end

@implementation FRZTransactor

#pragma mark Lifecycle

- (id)initWithStore:(FRZStore *)store {
	NSParameterAssert(store != nil);

	self = [super init];
	if (self == nil) return nil;

	_store = store;

	return self;
}

#pragma mark Keys

- (BOOL)addKey:(NSString *)key type:(FRZType)type collection:(BOOL)collection error:(NSError **)error {
	NSParameterAssert(key != nil);

	return [self.store performTransactionType:FRZStoreTransactionTypeExclusive withNewTransaction:YES error:error block:^(FMDatabase *database, long long txID, NSError **error) {
		BOOL success = [self insertIntoDatabase:database value:@(type) forKey:FRZStoreKeyTypeKey ID:key transactionID:txID error:error];
		if (!success) return NO;

		return [self insertIntoDatabase:database value:@(collection) forKey:FRZStoreKeyIsCollectionKey ID:key transactionID:txID error:error];
	}];
}

#pragma mark Changing

- (NSString *)generateNewID {
	// Problem?
	return [@"user/" stringByAppendingString:[[NSUUID UUID] UUIDString]];
}

- (BOOL)performChangesWithError:(NSError **)error block:(BOOL (^)(NSError **error))block {
	NSParameterAssert(block != NULL);

	return [self.store performWriteTransactionWithError:error block:^(FMDatabase *database, long long txID, NSError **error) {
		return block(error);
	}];
}

- (NSError *)invalidKeyErrorWithError:(NSError *)error {
	NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
	userInfo[NSLocalizedDescriptionKey] = NSLocalizedString(@"Invalid key", @"");
	if (error != nil) userInfo[NSUnderlyingErrorKey] = error;
	return [NSError errorWithDomain:FRZErrorDomain code:FRZErrorInvalidKey userInfo:userInfo];
}

- (BOOL)insertIntoDatabase:(FMDatabase *)database value:(id)value forKey:(NSString *)key ID:(NSString *)ID transactionID:(long long int)transactionID error:(NSError **)error {
	NSParameterAssert(database != nil);
	NSParameterAssert(value != nil);
	NSParameterAssert(key != nil);
	NSParameterAssert(ID != nil);

	NSData *data = [NSKeyedArchiver archivedDataWithRootObject:value];
	BOOL success = [database executeUpdate:@"INSERT INTO data (key, value, frz_id, tx_id) VALUES (?, ?, ?, ?)", key, data, ID, @(transactionID)];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return NO;
	}

	return YES;
}

- (long long int)insertNewTransactionIntoDatabase:(FMDatabase *)database error:(NSError **)error {
	NSParameterAssert(database != nil);

	BOOL success = [self insertIntoDatabase:database value:[NSDate date] forKey:FRZStoreTransactionDateKey ID:@"head" transactionID:0 error:error];
	if (!success) return -1;

	return database.lastInsertRowId;
}

- (BOOL)addValue:(id<NSCoding>)value forKey:(NSString *)key ID:(NSString *)ID error:(NSError **)error {
	NSParameterAssert(value != nil);
	NSParameterAssert(key != nil);
	NSParameterAssert(ID != nil);

	return [self.store performWriteTransactionWithError:error block:^(FMDatabase *database, long long txID, NSError **error) {
		BOOL isCollection = [self.store.databaseBeforeTransaction isCollectionKey:key];
		if (isCollection) {
			NSSet *existingValue = [self.store.databaseBeforeTransaction valueForID:ID key:key resolveReferences:NO] ?: [NSSet set];
			NSSet *newValue = [existingValue setByAddingObject:value];
			BOOL success = [self insertIntoDatabase:database value:newValue forKey:key ID:ID transactionID:txID error:error];
			if (!success) return NO;
		} else {
			BOOL success = [self insertIntoDatabase:database value:value forKey:key ID:ID transactionID:txID error:error];
			if (!success) return NO;
		}

		[self.store.queuedChanges addObject:[[FRZChange alloc] initWithType:FRZChangeTypeAdd ID:ID key:key delta:value]];

		return YES;
	}];
}

- (BOOL)updateHeadInDatabase:(FMDatabase *)database toID:(long long int)ID error:(NSError **)error {
	NSParameterAssert(database != nil);

	return [self insertIntoDatabase:database value:@(ID) forKey:FRZStoreHeadTransactionKey ID:@"head" transactionID:0 error:error];
}

- (BOOL)addValuesWithID:(NSString *)ID error:(NSError **)error block:(BOOL (^)(FRZSingleIDTransactor *transactor, NSError **error))block {
	NSParameterAssert(ID != nil);
	NSParameterAssert(block != NULL);

	FRZSingleIDTransactor *transactor = [[FRZSingleIDTransactor alloc] initWithTransactor:self ID:ID];
	return [self performChangesWithError:error block:^(NSError **error) {
		return block(transactor, error);
	}];
}

- (BOOL)removeValue:(id)value forKey:(NSString *)key ID:(NSString *)ID error:(NSError **)error {
	NSParameterAssert(value != nil);
	NSParameterAssert(key != nil);
	NSParameterAssert(ID != nil);

	return [self.store performWriteTransactionWithError:error block:^(FMDatabase *database, long long txID, NSError **error) {
		FRZDatabase *previousDatabase = self.store.databaseBeforeTransaction;
		BOOL isCollection = [previousDatabase isCollectionKey:key];
		id currentValue = [previousDatabase valueForID:ID key:key resolveReferences:NO];
		
		BOOL validRemoval = NO;
		if (isCollection) {
			validRemoval = [currentValue containsObject:value];
		} else {
			validRemoval = [currentValue isEqual:value];
		}

		if (!validRemoval) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Given value (%@) does not match current value (%@)", @""), value, currentValue];
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: description };
			if (error != NULL) *error = [NSError errorWithDomain:FRZErrorDomain code:FRZErrorInvalidValue userInfo:userInfo];
			return NO;
		}

		if (isCollection) {
			NSMutableSet *newSet = [currentValue mutableCopy];
			[newSet removeObject:value];
			id newValue;
			if (newSet.count < 1) {
				newValue = NSNull.null;
			} else {
				newValue = newSet;
			}

			BOOL success = [self insertIntoDatabase:database value:newValue forKey:key ID:ID transactionID:txID error:error];
			if (!success) return NO;
		} else {
			BOOL success = [self insertIntoDatabase:database value:NSNull.null forKey:key ID:ID transactionID:txID error:error];
			if (!success) return NO;
		}

		[self.store.queuedChanges addObject:[[FRZChange alloc] initWithType:FRZChangeTypeRemove ID:ID key:key delta:value]];

		return YES;
	}];
}

#pragma mark Trimming

- (NSString *)placeholderWithCount:(NSUInteger)placeholderCount {
	NSMutableString *placeholder = [NSMutableString string];
	for (NSUInteger i = 0; i < placeholderCount; i++) {
		if (i == 0) {
			[placeholder appendString:@"?"];
		} else {
			[placeholder appendString:@", ?"];
		}
	}

	return placeholder;
}

- (BOOL)trimOldIDs:(FMDatabase *)database error:(NSError **)error {
	// Remove the IDs of deleted entries.
	//
	// 1. Get all the IDs in the head of the database.
	// 2. Delete any entries with an ID not in that set.
	FRZDatabase *currentDatabase = self.store.databaseBeforeTransaction;
	NSArray *keys = currentDatabase.allIDs.allObjects;
	NSString *query = [NSString stringWithFormat:@"DELETE FROM data WHERE frz_id NOT IN (%@)", [self placeholderWithCount:keys.count]];
	BOOL success = [database executeUpdate:query withArgumentsInArray:keys];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return NO;
	}

	return YES;
}

- (BOOL)trimOldValues:(FMDatabase *)database error:(NSError **)error {
	// Remove old values of existing entries.
	//
	// 1. Get the IDs for all the latest values for the keys.
	// 2. Delete any entries with an ID not in that set.
	FRZDatabase *currentDatabase = self.store.databaseBeforeTransaction;
	for (NSString *key in currentDatabase.allIDs) {
		FMResultSet *set = [database executeQuery:@"SELECT id FROM data WHERE key = ? GROUP BY frz_id ORDER BY tx_id DESC", key];
		if (set == nil) {
			if (error != NULL) *error = database.lastError;
			return NO;
		}

		NSMutableArray *IDs = [NSMutableArray array];
		while ([set next]) {
			id ID = set[0];
			[IDs addObject:ID];
		}

		NSString *deleteQuery = [NSString stringWithFormat:@"DELETE FROM data WHERE key = ? AND id NOT IN (%@)", [self placeholderWithCount:IDs.count]];
		BOOL success = [database executeUpdate:deleteQuery withArgumentsInArray:[@[ key ] arrayByAddingObjectsFromArray:IDs]];
		if (!success) {
			if (error != NULL) *error = database.lastError;
			return NO;
		}
	}

	return YES;
}

- (BOOL)deleteEverythingButTheLastIDWithKey:(NSString *)key database:(FMDatabase *)database error:(NSError **)error {
	FMResultSet *set = [database executeQuery:@"SELECT id FROM data WHERE key = ? ORDER BY id DESC LIMIT 1", key];
	if (set == nil) {
		if (error != NULL) *error = database.lastError;
		return NO;
	}

	if (![set next]) return YES;

	NSString *headID = set[0];
	BOOL success = [database executeUpdate:@"DELETE FROM data WHERE key = ? AND id != ?", key, headID];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return NO;
	}

	return YES;
}

- (BOOL)trimOldTransactions:(FMDatabase *)database error:(NSError **)error {
	BOOL success = [self deleteEverythingButTheLastIDWithKey:FRZStoreTransactionDateKey database:database error:error];
	if (!success) return NO;

	return [self deleteEverythingButTheLastIDWithKey:FRZStoreHeadTransactionKey database:database error:error];
}

- (BOOL)trim:(NSError **)error {
	return [self.store performTransactionType:FRZStoreTransactionTypeExclusive withNewTransaction:NO error:error block:^(FMDatabase *database, long long txID, NSError **error) {
		BOOL success = [self trimOldIDs:database error:error];
		if (!success) return NO;

		success = [self trimOldValues:database error:error];
		if (!success) return NO;

		return [self trimOldTransactions:database error:error];
	}];
}

@end
