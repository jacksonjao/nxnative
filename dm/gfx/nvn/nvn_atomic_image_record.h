#pragma once
#import <Foundation/Foundation.h>
// Validate the separately reflected, compiled iOS ABI before opening its library.
// A nil digest performs schema/binding validation for the reflection converter.
static NSString *nvn_atomic_image_record_error(NSDictionary *j, NSString *digest) {
    NSDictionary *p = j[@"legacy_image_atomic"];
    if (![p isKindOfClass:NSDictionary.class] || ![p[@"schema"] isEqual:@1] ||
        ![p[@"kind"] isEqual:@"fragment-uint-max-2d-v1"] ||
        ![p[@"pixel_format"] isEqual:@"R32Uint"] || ![p[@"parameter_slot"] isEqual:@29] ||
        ![j[@"stage"] isEqual:@"ps"] || ![j[@"msl_entry_kind"] isEqual:@"fragment"])
        return @"Missing or invalid legacy atomic-image ABI";
    for (NSString *name in @[@"library_sha256", @"original_sha256", @"lowered_sha256"]) {
        NSString *value = p[name];
        if (![value isKindOfClass:NSString.class] || value.length != 64 ||
            [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound)
            return @"Invalid atomic-image source/library digest";
    }
    if (digest && ![p[@"library_sha256"] isEqual:digest]) return @"Atomic-image library digest mismatch";
    if (![p[@"image_aid"] isKindOfClass:NSNumber.class] || ![p[@"image_reg"] isKindOfClass:NSNumber.class] ||
        [p[@"image_aid"] intValue] < 0 || [p[@"image_aid"] intValue] >= 192 ||
        [p[@"image_reg"] intValue] < 0 || [p[@"image_reg"] intValue] >= 32)
        return @"Invalid atomic-image argument/register";
    NSArray *bindings = j[@"bindings"];
    if (![bindings isKindOfClass:NSArray.class]) return @"Missing atomic-image bindings";
    NSDictionary *raster = j[@"raster"];
    if (![raster isKindOfClass:NSDictionary.class] || ![raster[@"colors"] isEqual:@[]] || [raster[@"sample_mask"] boolValue])
        return @"Atomic-image ABI must not write raster outputs";
    if (![j[@"entry"] isKindOfClass:NSString.class] || ![j[@"entry"] length]) return @"Missing atomic-image entry";
    NSMutableSet *ids = [NSMutableSet set];
    NSSet *allowed = [NSSet setWithArray:@[@"img_atomic_2d", @"tex", @"samp", @"samp_tex", @"samp_id", @"cbuf", @"c1", @"support", @"drvcb", @"border"]];
    NSMutableSet *bits = [NSMutableSet set];
    int images = 0, samplers = 0, borders = 0;
    for (NSDictionary *b in bindings) {
        if (![b isKindOfClass:NSDictionary.class]) return @"Invalid atomic-image binding";
        NSString *kind = b[@"kind"], *type = b[@"msl_type"];
        NSNumber *aid = b[@"arg_id"], *reg = b[@"reg"];
        if (![allowed containsObject:kind] || ![type isKindOfClass:NSString.class] || [type containsString:@"array<"] ||
            ![aid isKindOfClass:NSNumber.class] || aid.intValue < 0 || aid.intValue >= 192 || [ids containsObject:aid])
            return @"Unsupported or duplicate atomic-image companion";
        [ids addObject:aid];
        int limit = [kind isEqual:@"cbuf"] ? 16 : [kind isEqual:@"samp_id"] ? 4096 :
            ([kind isEqual:@"tex"] || [kind isEqual:@"samp"] || [kind isEqual:@"samp_tex"]) ? 256 : 0;
        if (limit && (![reg isKindOfClass:NSNumber.class] || reg.intValue < 0 || reg.intValue >= limit)) return @"Invalid companion register";
        if ([kind isEqual:@"drvcb"] && ![b[@"bank"] isEqual:@0] && ![b[@"bank"] isEqual:@2]) return @"Invalid driver bank";
        if (![kind isEqual:@"img_atomic_2d"] && ([b[@"rw"] boolValue] || [b[@"atomic"] boolValue])) return @"Writable companion in shadow ABI";
        if ([kind hasPrefix:@"samp"] && (![type isEqual:@"sampler"] || ++samplers > 16)) return @"Invalid sampler companion";
        if ([kind isEqual:@"border"]) {
            if (![type isEqual:@"constant dm_border_t*"] || ![b[@"msl_name"] isEqual:@"dm_border"])
                return @"Invalid border constant companion";
            borders++;
        }
        id bit = b[@"border_bit"];
        if (bit) {
            NSString *name = b[@"msl_name"];
            if (![kind hasPrefix:@"samp"] || ![bit isKindOfClass:NSNumber.class] ||
                [bit doubleValue] != [bit intValue] || [bit intValue] < 0 || [bit intValue] >= 32 ||
                [bits containsObject:bit] || ![name isKindOfClass:NSString.class] || ![name hasSuffix:@"_w"])
                return @"Invalid border sampler companion";
            NSString *base = [name substringToIndex:name.length - 2];
            unsigned matches = 0;
            for (id x in bindings) {
                if (![x isKindOfClass:NSDictionary.class]) return @"Invalid atomic-image binding";
                if ([x[@"msl_name"] isEqual:base] && [x[@"kind"] isEqual:kind] && [x[@"reg"] isEqual:reg] &&
                    !x[@"border_bit"]) matches++;
            }
            if (matches != 1) return @"Border sampler has no unique matching base sampler";
            [bits addObject:bit];
        }
        if (([kind isEqual:@"cbuf"] || [kind isEqual:@"c1"] || [kind isEqual:@"support"] || [kind isEqual:@"drvcb"]) && ![type hasPrefix:@"constant "])
            return @"Invalid constant companion";
        if ([kind isEqual:@"tex"] && ((!([type hasPrefix:@"texture"] || [type hasPrefix:@"depth"])) || [type containsString:@"access::write"] || [type containsString:@"access::read_write"]))
            return @"Invalid sampled companion";
        if ([b[@"kind"] isEqual:@"img"] || [b[@"atomic"] boolValue]) return @"Native image mixed with shadow ABI";
        if (![b[@"kind"] isEqual:@"img_atomic_2d"]) continue;
        if (![b[@"arg_id"] isEqual:p[@"image_aid"]] || ![b[@"reg"] isEqual:p[@"image_reg"]] ||
            ![b[@"msl_name"] isEqual:p[@"image_name"]] || ![b[@"msl_type"] isEqual:@"device atomic_uint*"] || ![b[@"rw"] isEqual:@YES])
            return @"Atomic-image reflection does not match its proof";
        images++;
    }
    if (borders != (bits.count != 0)) return @"Border samplers require exactly one read-only border block";
    return images == 1 ? nil : @"Expected exactly one shadow image binding";
}
