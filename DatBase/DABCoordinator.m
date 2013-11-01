//
//  DABCoordinator.m
//  DatBase
//
//  Created by Josh Abernathy on 10/9/13.
//  Copyright (c) 2013 Josh Abernathy. All rights reserved.
//

#import "DABCoordinator.h"
#import "DABCoordinator+Private.h"
#import "DABDatabase+Private.h"
#import "DABTransactor+Private.h"
#import "FMDatabase.h"

static NSString * const DABCoordinatorDatabaseKey = @"DABCoordinatorDatabaseKey";

NSString * const DABRefsTableName = @"refs";
NSString * const DABEntitiesTableName = @"entities";
NSString * const DABTransactionsTableName = @"txs";
NSString * const DABTransactionToEntityTableName = @"tx_to_entity";

NSString * const DABHeadRefName = @"head";

@interface DABCoordinator ()

@property (nonatomic, readonly, copy) NSString *databasePath;

@end

@implementation DABCoordinator

- (id)initWithPath:(NSString *)path error:(NSError **)error {
	self = [super init];
	if (self == nil) return nil;

	_databasePath = [path copy];

	// Preflight the database so we get fatal errors earlier.
	FMDatabase *database = [self createDatabase:error];
	if (database == nil) return nil;

	return self;
}

- (id)initInMemory:(NSError **)error {
	return [self initWithPath:nil error:error];
}

- (id)initWithDatabaseAtURL:(NSURL *)URL error:(NSError **)error {
	NSParameterAssert(URL != nil);

	return [self initWithPath:URL.path error:error];
}

- (FMDatabase *)createDatabase:(NSError **)error {
	FMDatabase *database = [FMDatabase databaseWithPath:self.databasePath];
	// No mutex, no cry.
	BOOL success = [database openWithFlags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	return database;
}

- (FMDatabase *)createAndConfigureDatabase:(NSError **)error {
	FMDatabase *database = [self createDatabase:error];
	if (database == nil) return nil;

	database.shouldCacheStatements = YES;

	BOOL success = [database executeUpdate:@"PRAGMA legacy_file_format = 0;"];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	success = [database executeUpdate:@"PRAGMA foreign_keys = ON;"];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	// Write-ahead logging lets us read and write concurrently.
	//
	// Note that we're using -executeQuery: here, instead of -executeUpdate: The
	// result of turning on WAL is a row, which really rustles FMDB's jimmies if
	// done from -executeUpdate. So we pacify it by setting WAL in a "query."
	FMResultSet *set = [database executeQuery:@"PRAGMA journal_mode = WAL;"];
	if (set == nil) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	NSString *txsSchema = [NSString stringWithFormat:
		@"CREATE TABLE IF NOT EXISTS %@("
			"id INTEGER PRIMARY KEY AUTOINCREMENT,"
			"date DATETIME NOT NULL"
		");",
		DABTransactionsTableName];
	success = [database executeUpdate:txsSchema];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	NSString *refsSchema = [NSString stringWithFormat:
		@"CREATE TABLE IF NOT EXISTS %@("
			"id INTEGER PRIMARY KEY AUTOINCREMENT,"
			"tx_id INTEGER NOT NULL,"
			"name TEXT NOT NULL,"
			"FOREIGN KEY(tx_id) REFERENCES %@(id)"
		");",
		DABRefsTableName,
		DABTransactionsTableName];
	success = [database executeUpdate:refsSchema];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	NSString *entitiesSchema = [NSString stringWithFormat:
		@"CREATE TABLE IF NOT EXISTS %@("
			"id INTEGER PRIMARY KEY AUTOINCREMENT,"
			"attribute TEXT NOT NULL,"
			"value BLOB NOT NULL,"
			"key STRING NOT NULL,"
			"tx_id INTEGER NOT NULL,"
			"FOREIGN KEY(tx_id) REFERENCES %@(id)"
		");",
		DABEntitiesTableName,
		DABTransactionsTableName];
	success = [database executeUpdate:entitiesSchema];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	NSString *txToEntitySchema = [NSString stringWithFormat:
		@"CREATE TABLE IF NOT EXISTS %@("
			"tx_id INTEGER NOT NULL,"
			"entity_id INTEGER NOT NULL,"
			"FOREIGN KEY(tx_id) REFERENCES %@(id),"
			"FOREIGN KEY(entity_id) REFERENCES %@(id)"
		");",
		DABTransactionToEntityTableName,
		DABTransactionsTableName,
		DABEntitiesTableName];
	success = [database executeUpdate:txToEntitySchema];
	if (!success) {
		if (error != NULL) *error = database.lastError;
		return nil;
	}

	return database;
}

- (long long int)headID:(NSError **)error {
	long long int headID = 0;
	NSString *query = [NSString stringWithFormat:@"SELECT tx_id from %@ WHERE name = ? LIMIT 1", DABRefsTableName];
	FMResultSet *set = [self.database executeQuery:query, DABHeadRefName];
	if ([set next]) {
		headID = [set longLongIntForColumnIndex:0];
	}

	return headID;
}

- (DABDatabase *)currentDatabase:(NSError **)error {
	long long int headID = [self headID:error];
	if (headID < 0) return nil;

	return [[DABDatabase alloc] initWithCoordinator:self transactionID:headID];
}

- (void)performConcurrentBlock:(void (^)(FMDatabase *database))block {
	NSParameterAssert(block != NULL);

	// TODO: Can this be concurrent? Sqlite docs are unclear about WAL mode. If
	// not, we could use a thread-local db connection instead. For now we'll
	// play it safe.
	dispatch_barrier_sync(self.databaseQueue, ^{
		block(self.database);
	});
}

- (void)performExclusiveBlock:(void (^)(FMDatabase *database))block {
	NSParameterAssert(block != NULL);

	dispatch_barrier_sync(self.databaseQueue, ^{
		block(self.database);
	});
}

- (DABTransactor *)transactor {
	return [[DABTransactor alloc] initWithCoordinator:self];
}

- (FMDatabase *)databaseForCurrentThread:(NSError **)error {
	@synchronized (self) {
		FMDatabase *database = NSThread.currentThread.threadDictionary[DABCoordinatorDatabaseKey];
		if (database == nil) {
			database = [self createAndConfigureDatabase:error];
			if (database == nil) return nil;

			NSThread.currentThread.threadDictionary[DABCoordinatorDatabaseKey] = database;
		}

		return database;
	}
}

@end
