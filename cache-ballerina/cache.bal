// Copyright (c) 2020 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/jballerina.java;
import ballerina/io;
import ballerina/task;
import ballerina/time;

# Represents configurations for the `cache:Cache` object.
#
# + capacity - Maximum number of entries allowed in the cache
# + evictionFactor - The factor by which the entries will be evicted once the cache is full
# + evictionPolicy - The policy which is used to evict entries once the cache is full
# + defaultMaxAgeInSeconds - The default value in seconds which all the cache entries are valid.
#                            '-1' means, the entries are valid forever. This will be overwritten by the the
#                            `maxAgeInSeconds` property set when inserting item to the cache
# + cleanupIntervalInSeconds - Interval of the timer task, which will clean up the cache
public type CacheConfig record {|
    int capacity = 100;
    float evictionFactor = 0.25;
    EvictionPolicy evictionPolicy = LRU;
    int defaultMaxAgeInSeconds = -1;
    int cleanupIntervalInSeconds?;
|};

# Possible types of eviction policy that can be passed into the `EvictionPolicy`
public enum EvictionPolicy {
    LRU
}

public type CacheEntry record {|
    string key;
    any data;
    int expTime;       // exp time since epoch. calculated based on the `maxAge` parameter when inserting to map
|};

type Data record {|
    string key;
    Node node;
|};

// Cleanup service which cleans the cache entries periodically.
boolean cleanupInProgress = false;

// Cleanup service which cleans the cache entries periodically.
final service isolated object{} cleanupService = service object {
    remote function onTrigger(map<Node> cacheMap, LinkedList linkedList) {
        // This check will skip the processes triggered while the clean up in progress.
        if (!cleanupInProgress) {
            cleanupInProgress = true;
            cleanup(cacheMap, linkedList);
            cleanupInProgress = false;
        }
    }
};

# The `cache:Cache` object, which is used for all the cache-related operations. It is not recommended to insert `()`
# as the value of the cache since it doesn't make any sense to cache a nil.
public class Cache {

    *AbstractCache;

    private int maxCapacity;
    private EvictionPolicy evictionPolicy;
    private float evictionFactor;
    private int defaultMaxAgeInSeconds;
    private LinkedList linkedList;
    private map<Node> cacheMap = {};

    # Called when a new `cache:Cache` object is created.
    #
    # + cacheConfig - Configurations for the `cache:Cache` object
    public isolated function init(CacheConfig cacheConfig = {}) {
        io:println("#####################################");
        self.maxCapacity = cacheConfig.capacity;
        self.evictionPolicy = cacheConfig.evictionPolicy;
        self.evictionFactor = cacheConfig.evictionFactor;
        self.defaultMaxAgeInSeconds = cacheConfig.defaultMaxAgeInSeconds;
        self.linkedList = new LinkedList();

        // Cache capacity must be a positive value.
        if (self.maxCapacity <= 0) {
            panic prepareError("Capacity must be greater than 0.");
        }
        // Cache eviction factor must be between 0.0 (exclusive) and 1.0 (inclusive).
        if (self.evictionFactor <= 0 || self.evictionFactor > 1) {
            panic prepareError("Cache eviction factor must be between 0.0 (exclusive) and 1.0 (inclusive).");
        }

        // Cache eviction factor must be between 0.0 (exclusive) and 1.0 (inclusive).
        if (self.defaultMaxAgeInSeconds != -1 && self.defaultMaxAgeInSeconds <= 0) {
            panic prepareError("Default max age should be greater than 0 or -1 for indicate forever valid.");
        }

        externInit();

        int? cleanupIntervalInSeconds = cacheConfig?.cleanupIntervalInSeconds;
        if (cleanupIntervalInSeconds is int) {
            task:TimerConfiguration timerConfiguration = {
                intervalInMillis: cleanupIntervalInSeconds,
                initialDelayInMillis: cleanupIntervalInSeconds
            };
            task:Scheduler|task:SchedulerError cleanupScheduler = new(timerConfiguration);
            if (cleanupScheduler is task:Scheduler) {
                task:SchedulerError? result = cleanupScheduler.attach(cleanupService, self.cacheMap, self.linkedList);
                if (result is task:SchedulerError) {
                    panic prepareError("Failed to attach the cache cleanup task.", result);
                }
                result = cleanupScheduler.start();
                if (result is task:SchedulerError) {
                    panic prepareError("Failed to start the cache cleanup task.", result);
                }
            } else {
                panic prepareError("Failed to initialize the cache cleanup task.", cleanupScheduler);
            }
        }
    }

    # Adds the given key value pair to the cache. If the cache previously contained a value associated with the
    # provided key, the old value wil be replaced by the newly-provided value.
    #
    # + key - Key of the value to be cached
    # + value - Value to be cached. Value should not be `()`
    # + maxAgeInSeconds - The time in seconds for which the cache entry is valid. If the value is '-1', the entry is
    #                     valid forever.
    # + return - `()` if successfully added to the cache or `Error` if a `()` value is inserted to the cache.
    public isolated function put(string key, any value, int maxAgeInSeconds = -1) returns Error? {
        if (value is ()) {
            return prepareError("Unsupported cache value '()' for the key: " + key + ".");
        }
        // If the current cache is full (i.e. size = capacity), evict cache.
        if (self.size() == self.maxCapacity) {
            evict(self.cacheMap, self.maxCapacity, self.evictionFactor, self.linkedList);
        }

        // Calculate the `expTime` of the cache entry based on the `maxAgeInSeconds` property and
        // `defaultMaxAgeInSeconds` property.
        int calculatedExpTime = -1;
        if (maxAgeInSeconds != -1 && maxAgeInSeconds > 0) {
            calculatedExpTime = time:nanoTime() + (maxAgeInSeconds * 1000 * 1000 * 1000);
        } else {
            if (self.defaultMaxAgeInSeconds != -1) {
                calculatedExpTime = time:nanoTime() + (self.defaultMaxAgeInSeconds * 1000 * 1000 * 1000);
            }
        }
        acquire();
        CacheEntry entry = {
            key: key,
            data: value,
            expTime: calculatedExpTime
        };
        Node newNode = { value: entry };

        if (self.hasKey(key)) {
            Node oldNode = self.cacheMap.get(key);
            // Move the node to front
            self.linkedList.remove(oldNode);
            self.linkedList.addFirst(newNode);
        } else {
            self.linkedList.addFirst(newNode);
        }
        self.cacheMap[key] = newNode;
        release();
    }

    # Returns the cached value associated with the provided key.
    #
    # + key - Key of the cached value, which should be retrieved
    # + return - The cached value associated with the provided key or an `Error` if the provided cache key is not
    #            exisiting in the cache or any error occurred while retrieving the value from the cache.
    public isolated function get(string key) returns any|Error {
        if (!self.hasKey(key)) {
            return prepareError("Cache entry from the given key: " + key + ", is not available.");
        }
        acquire();
        Node node =  self.cacheMap.get(key);
        CacheEntry entry = <CacheEntry>node.value;

        // Check whether the cache entry is already expired. Even though the cache cleaning task is configured
        // and runs in predefined intervals, sometimes the cache entry might not have been removed at this point
        // even though it is expired. So this check guarantees that the expired cache entries will not be returned.
        if (entry.expTime != -1 && entry.expTime < time:nanoTime()) {
            self.linkedList.remove(node);
            var result = self.cacheMap.remove(key);
            return ();
        }
        // Move the node to front
        self.linkedList.remove(node);
        self.linkedList.addFirst(node);
        release();
        return entry.data;
    }

    # Discards a cached value from the cache.
    #
    # + key - Key of the cache value, which needs to be discarded from the cache
    # + return - `()` if successfully discarded the value or an `Error` if the provided cache key is not present in the
    #            cache
    public isolated function invalidate(string key) returns Error? {
        if (!self.hasKey(key)) {
            return prepareError("Cache entry from the given key: " + key + ", is not available.");
        }
        acquire();
        Node node = self.cacheMap.get(key);
        self.linkedList.remove(node);
        var result = self.cacheMap.remove(key);
        release();
    }

    # Discards all the cached values from the cache.
    #
    # + return - `()` if successfully discarded all the values from the cache or an `Error` if any error occurred while
    # discarding all the values from the cache.
    public isolated function invalidateAll() returns Error? {
        acquire();
        self.linkedList.clear();
        release();
        self.cacheMap.removeAll();
    }

    # Checks whether the given key has an associated cached value.
    #
    # + key - The key to be checked in the cache
    # + return - `true` if a cached value is available for the provided key or `false` if there is no cached value
    #            associated for the given key
    public isolated function hasKey(string key) returns boolean {
        return self.cacheMap.hasKey(key);
    }

    # Returns a list of all the keys from the cache.
    #
    # + return - Array of all the keys from the cache
    public isolated function keys() returns string[] {
        return self.cacheMap.keys();
    }

    # Returns the size of the cache.
    #
    # + return - The size of the cache
    public isolated function size() returns int {
        return self.cacheMap.length();
    }

    # Returns the capacity of the cache.
    #
    # + return - The capacity of the cache
    public isolated function capacity() returns int {
        return self.maxCapacity;
    }
}

isolated function evict(map<Node> cacheMap, int capacity, float evictionFactor, LinkedList linkedList) {
    int evictionKeysCount = <int>(capacity * evictionFactor);
    acquire();
    foreach int i in 1...evictionKeysCount {
        Node? node = linkedList.removeLast();
        if (node is Node) {
            CacheEntry entry = <CacheEntry>node.value;
            var result = cacheMap.remove(entry.key);
            // The return result (error which occurred due to unavailability of the key or nil) is ignored
            // since no purpose of handling it.
        } else {
            break;
        }
    }
    release();
}

isolated function cleanup(map<Node> cacheMap, LinkedList linkedList) {
    if (cacheMap.length() == 0) {
        return;
    }
    foreach string key in cacheMap.keys() {
        Node node = cacheMap.get(key);
        CacheEntry entry = <CacheEntry>node.value;
        if (entry.expTime != -1 && entry.expTime < time:nanoTime()) {
            acquire();
            linkedList.remove(node);
            var result = cacheMap.remove(entry.key);
            release();
            // The return result (error which occurred due to unavailability of the key or nil) is ignored
            // since no purpose of handling it.
            return;
        }
    }
}

isolated function externInit() = @java:Method {
    name: "init",
    'class: "org.ballerinalang.stdlib.cache.nativeimpl.SemaphoreAsLock"
} external;

isolated function acquire() = @java:Method {
    'class: "org.ballerinalang.stdlib.cache.nativeimpl.SemaphoreAsLock"
} external;

isolated function release() = @java:Method {
    'class: "org.ballerinalang.stdlib.cache.nativeimpl.SemaphoreAsLock"
} external;
