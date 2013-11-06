//
//  FRZChange.m
//  Freezer
//
//  Created by Josh Abernathy on 11/6/13.
//  Copyright (c) 2013 Josh Abernathy. All rights reserved.
//

#import "FRZChange.h"
#import "FRZChange+Private.h"
#import "FRZDatabase.h"

@implementation FRZChange

#pragma mark Lifecycle

- (id)initWithType:(FRZChangeType)type key:(NSString *)key attribute:(NSString *)attribute delta:(id)delta previousDatabase:(FRZDatabase *)previousDatabase changedDatabase:(FRZDatabase *)changedDatabase {
	NSParameterAssert(key != nil);
	NSParameterAssert(attribute != nil);
	NSParameterAssert(previousDatabase != nil);
	NSParameterAssert(changedDatabase != nil);

	self = [super init];
	if (self == nil) return nil;

	_type = type;
	_key = [key copy];
	_attribute = [attribute copy];
	_delta = delta;
	_previousDatabase = [previousDatabase copyWithZone:nil];
	_changedDatabase = [changedDatabase copyWithZone:nil];

	return self;
}

#pragma mark NSObject

- (NSString *)description {
	NSDictionary *typeToTypeName = @{
		@(FRZChangeTypeAdd): @"add",
		@(FRZChangeTypeAddMany): @"add many",
		@(FRZChangeTypeRemove): @"remove",
		@(FRZChangeTypeRemoveMany): @"remove many",
	};
	NSString *typeName = typeToTypeName[@(self.type)];

	return [NSString stringWithFormat:@"<%@: %p> type: %@, key: %@, attribute: %@, delta: %@", self.class, self, typeName, self.key, self.attribute, self.delta];
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone {
	return self;
}

@end