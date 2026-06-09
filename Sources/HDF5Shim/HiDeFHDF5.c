// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

#include "HiDeFHDF5.h"

#include <hdf5.h>

#include <float.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct HDHDFFile {
    hid_t fileID;
    char *path;
};

typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
} HDStringBuilder;

static char *hd_copy_string(const char *string)
{
    if (string == NULL)
        return NULL;

    size_t length = strlen(string);
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL)
        return NULL;

    memcpy(copy, string, length + 1);
    return copy;
}

static char *hd_format_string(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int length = vsnprintf(NULL, 0, format, args);
    va_end(args);

    if (length < 0)
        return hd_copy_string("Formatting error");

    char *string = (char *)malloc((size_t)length + 1);
    if (string == NULL)
        return NULL;

    va_start(args, format);
    vsnprintf(string, (size_t)length + 1, format, args);
    va_end(args);
    return string;
}

static bool hd_sb_reserve(HDStringBuilder *builder, size_t additionalBytes)
{
    if (builder->length + additionalBytes + 1 <= builder->capacity)
        return true;

    size_t nextCapacity = builder->capacity == 0 ? 256 : builder->capacity;
    while (builder->length + additionalBytes + 1 > nextCapacity) {
        if (nextCapacity > (SIZE_MAX / 2))
            return false;
        nextCapacity *= 2;
    }

    char *next = (char *)realloc(builder->bytes, nextCapacity);
    if (next == NULL)
        return false;

    builder->bytes = next;
    builder->capacity = nextCapacity;
    return true;
}

static bool hd_sb_append(HDStringBuilder *builder, const char *string)
{
    if (string == NULL)
        string = "";

    size_t length = strlen(string);
    if (!hd_sb_reserve(builder, length))
        return false;

    memcpy(builder->bytes + builder->length, string, length);
    builder->length += length;
    builder->bytes[builder->length] = '\0';
    return true;
}

static bool hd_sb_append_bytes(HDStringBuilder *builder, const char *bytes, size_t length)
{
    if (bytes == NULL || length == 0)
        return true;

    if (!hd_sb_reserve(builder, length))
        return false;

    memcpy(builder->bytes + builder->length, bytes, length);
    builder->length += length;
    builder->bytes[builder->length] = '\0';
    return true;
}

static bool hd_sb_appendf(HDStringBuilder *builder, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int length = vsnprintf(NULL, 0, format, args);
    va_end(args);

    if (length < 0)
        return false;

    if (!hd_sb_reserve(builder, (size_t)length))
        return false;

    va_start(args, format);
    vsnprintf(builder->bytes + builder->length, (size_t)length + 1, format, args);
    va_end(args);
    builder->length += (size_t)length;
    return true;
}

static char *hd_sb_finish(HDStringBuilder *builder)
{
    if (builder->bytes == NULL)
        return hd_copy_string("");

    char *finished = builder->bytes;
    builder->bytes = NULL;
    builder->length = 0;
    builder->capacity = 0;
    return finished;
}

static void hd_sb_dispose(HDStringBuilder *builder)
{
    free(builder->bytes);
    builder->bytes = NULL;
    builder->length = 0;
    builder->capacity = 0;
}

static int hd_float_roundtrip_digits(hid_t typeID)
{
    size_t byteCount = H5Tget_size(typeID);
    return byteCount <= sizeof(float) ? 9 : 17;
}

static int hd_float_display_precision(hid_t typeID)
{
    size_t byteCount = H5Tget_size(typeID);
    return byteCount <= sizeof(float) ? FLT_DECIMAL_DIG : DBL_DECIMAL_DIG;
}

static bool hd_append_floating_value(HDStringBuilder *builder, double value, int significantDigits)
{
    int digits = significantDigits <= 0 ? DBL_DECIMAL_DIG : significantDigits;
    return hd_sb_appendf(builder, "%.*g", digits, value);
}

static char *hd_copy_repeated_precision_list(int precision, uint64_t count)
{
    HDStringBuilder builder = {0};
    for (uint64_t index = 0; index < count; index++) {
        if (index > 0)
            hd_sb_append(&builder, "\t");
        hd_sb_appendf(&builder, "%d", precision);
    }
    return hd_sb_finish(&builder);
}

static void hd_set_error(char **errorMessage, const char *format, ...)
{
    if (errorMessage == NULL)
        return;

    va_list args;
    va_start(args, format);
    int length = vsnprintf(NULL, 0, format, args);
    va_end(args);

    if (length < 0) {
        *errorMessage = hd_copy_string("Unknown HDF5 error");
        return;
    }

    char *message = (char *)malloc((size_t)length + 1);
    if (message == NULL) {
        *errorMessage = NULL;
        return;
    }

    va_start(args, format);
    vsnprintf(message, (size_t)length + 1, format, args);
    va_end(args);
    *errorMessage = message;
}

static char *hd_last_path_component(const char *path)
{
    if (path == NULL || path[0] == '\0' || strcmp(path, "/") == 0)
        return hd_copy_string("/");

    const char *slash = strrchr(path, '/');
    return hd_copy_string(slash == NULL ? path : slash + 1);
}

static char *hd_join_path(const char *parent, const char *name)
{
    if (parent == NULL || parent[0] == '\0' || strcmp(parent, "/") == 0)
        return hd_format_string("/%s", name == NULL ? "" : name);

    return hd_format_string("%s/%s", parent, name == NULL ? "" : name);
}

static char *hd_parent_path(const char *path)
{
    if (path == NULL || path[0] == '\0' || strcmp(path, "/") == 0)
        return hd_copy_string("/");

    const char *slash = strrchr(path, '/');
    if (slash == NULL || slash == path)
        return hd_copy_string("/");

    size_t length = (size_t)(slash - path);
    char *parent = (char *)malloc(length + 1);
    if (parent == NULL)
        return NULL;

    memcpy(parent, path, length);
    parent[length] = '\0';
    return parent;
}

static HDHDFLinkKind hd_link_kind_from_hdf5(H5L_type_t type)
{
    switch (type) {
    case H5L_TYPE_HARD:
        return HDHDFLinkKindHard;
    case H5L_TYPE_SOFT:
        return HDHDFLinkKindSoft;
    case H5L_TYPE_EXTERNAL:
        return HDHDFLinkKindExternal;
    case H5L_TYPE_ERROR:
        return HDHDFLinkKindUnknown;
    default:
        return HDHDFLinkKindUserDefined;
    }
}

static char *hd_copy_link_target(hid_t parentID, const char *name, const H5L_info2_t *linkInfo)
{
    if (linkInfo == NULL)
        return NULL;

    if (linkInfo->type != H5L_TYPE_SOFT && linkInfo->type != H5L_TYPE_EXTERNAL)
        return NULL;

    size_t size = linkInfo->u.val_size;
    char *value = (char *)calloc(size + 1, 1);
    if (value == NULL)
        return NULL;

    if (H5Lget_val(parentID, name, value, size + 1, H5P_DEFAULT) < 0) {
        free(value);
        return NULL;
    }

    return value;
}

static char *hd_copy_datatype_description(hid_t typeID)
{
    H5T_class_t typeClass = H5Tget_class(typeID);
    size_t byteSize = H5Tget_size(typeID);

    switch (typeClass) {
    case H5T_INTEGER: {
        H5T_sign_t sign = H5Tget_sign(typeID);
        const char *prefix = sign == H5T_SGN_NONE ? "unsigned" : "signed";
        return hd_format_string("%s %zu-bit integer", prefix, byteSize * 8);
    }
    case H5T_FLOAT:
        return hd_format_string("%zu-bit float", byteSize * 8);
    case H5T_STRING:
        if (H5Tis_variable_str(typeID) > 0)
            return hd_copy_string("variable-length string");
        return hd_format_string("fixed-length string[%zu]", byteSize);
    case H5T_BITFIELD:
        return hd_format_string("%zu-bit bitfield", byteSize * 8);
    case H5T_OPAQUE:
        return hd_format_string("opaque[%zu]", byteSize);
    case H5T_COMPOUND:
        return hd_format_string("compound (%d members)", H5Tget_nmembers(typeID));
    case H5T_REFERENCE:
        return hd_copy_string("reference");
    case H5T_ENUM:
        return hd_format_string("enum (%zu-bit)", byteSize * 8);
    case H5T_VLEN:
        return hd_copy_string("variable-length sequence");
    case H5T_ARRAY:
        return hd_copy_string("array");
    default:
        return hd_copy_string("unknown datatype");
    }
}

static bool hd_can_preview_attribute_value(hid_t typeID, hsize_t elementCount, size_t valueByteLimit)
{
    if (elementCount == 0 || elementCount > 256)
        return false;

    H5T_class_t typeClass = H5Tget_class(typeID);
    if (typeClass == H5T_STRING && H5Tis_variable_str(typeID) > 0)
        return true;

    size_t typeSize = H5Tget_size(typeID);
    if (typeSize == 0 || typeSize == H5T_VARIABLE)
        return false;

    return elementCount <= (hsize_t)(valueByteLimit / typeSize);
}

static char *hd_copy_shape_description(hid_t dataspaceID)
{
    H5S_class_t spaceClass = H5Sget_simple_extent_type(dataspaceID);
    if (spaceClass == H5S_NULL)
        return hd_copy_string("null");
    if (spaceClass == H5S_SCALAR)
        return hd_copy_string("scalar");

    int rank = H5Sget_simple_extent_ndims(dataspaceID);
    if (rank < 0)
        return hd_copy_string("unknown shape");
    if (rank == 0)
        return hd_copy_string("scalar");

    hsize_t *dims = (hsize_t *)calloc((size_t)rank, sizeof(hsize_t));
    hsize_t *maxDims = (hsize_t *)calloc((size_t)rank, sizeof(hsize_t));
    if (dims == NULL || maxDims == NULL) {
        free(dims);
        free(maxDims);
        return hd_copy_string("unknown shape");
    }

    if (H5Sget_simple_extent_dims(dataspaceID, dims, maxDims) < 0) {
        free(dims);
        free(maxDims);
        return hd_copy_string("unknown shape");
    }

    HDStringBuilder builder = {0};
    for (int index = 0; index < rank; index++) {
        if (index > 0)
            hd_sb_append(&builder, " x ");
        hd_sb_appendf(&builder, "%llu", (unsigned long long)dims[index]);
        if (maxDims[index] == H5S_UNLIMITED)
            hd_sb_append(&builder, " (unlimited)");
    }

    free(dims);
    free(maxDims);
    return hd_sb_finish(&builder);
}

static uint64_t hd_group_child_count(hid_t groupID)
{
    H5G_info_t info;
    if (H5Gget_info(groupID, &info) < 0)
        return 0;

    return (uint64_t)info.nlinks;
}

static void hd_fill_dataset_info(hid_t datasetID, HDHDFObjectInfo *info)
{
    hid_t dataspaceID = H5Dget_space(datasetID);
    if (dataspaceID >= 0) {
        info->shapeDescription = hd_copy_shape_description(dataspaceID);
        H5Sclose(dataspaceID);
    }

    hid_t datatypeID = H5Dget_type(datasetID);
    if (datatypeID >= 0) {
        info->typeDescription = hd_copy_datatype_description(datatypeID);
        H5Tclose(datatypeID);
    }

    hsize_t storageSize = H5Dget_storage_size(datasetID);
    info->storageSize = (uint64_t)storageSize;
}

static bool hd_fill_object_info(HDHDFFile *file,
                                const char *path,
                                const char *nameOverride,
                                const H5L_info2_t *linkInfo,
                                hid_t parentID,
                                HDHDFObjectInfo *outInfo,
                                char **errorMessage)
{
    memset(outInfo, 0, sizeof(*outInfo));
    outInfo->name = nameOverride == NULL ? hd_last_path_component(path) : hd_copy_string(nameOverride);
    outInfo->path = hd_copy_string(path);
    outInfo->linkKind = linkInfo == NULL ? HDHDFLinkKindHard : hd_link_kind_from_hdf5(linkInfo->type);
    outInfo->kind = HDHDFObjectKindUnknown;
    outInfo->shapeDescription = hd_copy_string("");
    outInfo->typeDescription = hd_copy_string("");
    outInfo->linkTarget = linkInfo == NULL ? NULL : hd_copy_link_target(parentID, nameOverride, linkInfo);

    if (linkInfo != NULL && linkInfo->type != H5L_TYPE_HARD) {
        outInfo->kind = HDHDFObjectKindLink;
        return true;
    }

    H5O_info2_t objectInfo;
    if (H5Oget_info_by_name3(file->fileID, path, &objectInfo, H5O_INFO_BASIC | H5O_INFO_NUM_ATTRS, H5P_DEFAULT) < 0) {
        hd_set_error(errorMessage, "Could not inspect object at %s", path == NULL ? "(null)" : path);
        return false;
    }

    outInfo->attributeCount = (uint64_t)objectInfo.num_attrs;

    switch (objectInfo.type) {
    case H5O_TYPE_GROUP: {
        outInfo->kind = HDHDFObjectKindGroup;
        hid_t groupID = H5Gopen2(file->fileID, path, H5P_DEFAULT);
        if (groupID >= 0) {
            outInfo->childCount = hd_group_child_count(groupID);
            H5Gclose(groupID);
        }
        break;
    }
    case H5O_TYPE_DATASET: {
        outInfo->kind = HDHDFObjectKindDataset;
        hid_t datasetID = H5Dopen2(file->fileID, path, H5P_DEFAULT);
        if (datasetID >= 0) {
            hd_fill_dataset_info(datasetID, outInfo);
            H5Dclose(datasetID);
        }
        break;
    }
    case H5O_TYPE_NAMED_DATATYPE: {
        outInfo->kind = HDHDFObjectKindNamedDatatype;
        hid_t typeID = H5Topen2(file->fileID, path, H5P_DEFAULT);
        if (typeID >= 0) {
            free(outInfo->typeDescription);
            outInfo->typeDescription = hd_copy_datatype_description(typeID);
            H5Tclose(typeID);
        }
        break;
    }
    default:
        outInfo->kind = HDHDFObjectKindUnknown;
        break;
    }

    return true;
}

HDHDFFile *HDHDFOpenFile(const char *path, char **errorMessage)
{
    if (path == NULL || path[0] == '\0') {
        hd_set_error(errorMessage, "No HDF5 file path was provided");
        return NULL;
    }

    H5Eset_auto2(H5E_DEFAULT, NULL, NULL);

    // Open read-only with file locking disabled. This lets HiDeF view a file that
    // another process (e.g. a data logger) currently has open for writing, without
    // taking an HDF5 lock that would block the writer or being blocked by it.
    // Reads can briefly see a partially written state; reload re-issues them.
    hid_t accessPlist = H5Pcreate(H5P_FILE_ACCESS);
    if (accessPlist >= 0) {
        H5Pset_file_locking(accessPlist, false, true);
    }

    hid_t fileID = H5Fopen(path, H5F_ACC_RDONLY, accessPlist >= 0 ? accessPlist : H5P_DEFAULT);
    if (accessPlist >= 0) {
        H5Pclose(accessPlist);
    }
    if (fileID < 0) {
        hd_set_error(errorMessage, "Could not open %s as an HDF5 file", path);
        return NULL;
    }

    HDHDFFile *file = (HDHDFFile *)calloc(1, sizeof(HDHDFFile));
    if (file == NULL) {
        H5Fclose(fileID);
        hd_set_error(errorMessage, "Out of memory while opening %s", path);
        return NULL;
    }

    file->fileID = fileID;
    file->path = hd_copy_string(path);
    return file;
}

void HDHDFCloseFile(HDHDFFile *file)
{
    if (file == NULL)
        return;

    if (file->fileID >= 0)
        H5Fclose(file->fileID);
    free(file->path);
    free(file);
}

HDHDFObjectInfo HDHDFCopyRootObjectInfo(HDHDFFile *file, char **errorMessage)
{
    HDHDFObjectInfo info;
    memset(&info, 0, sizeof(info));

    if (file == NULL) {
        hd_set_error(errorMessage, "No HDF5 file is open");
        return info;
    }

    if (!hd_fill_object_info(file, "/", "/", NULL, file->fileID, &info, errorMessage))
        return info;

    free(info.name);
    info.name = hd_last_path_component(file->path);
    return info;
}

HDHDFObjectInfo HDHDFCopyObjectInfo(HDHDFFile *file, const char *path, char **errorMessage)
{
    HDHDFObjectInfo info;
    memset(&info, 0, sizeof(info));

    if (file == NULL) {
        hd_set_error(errorMessage, "No HDF5 file is open");
        return info;
    }

    if (path == NULL || path[0] == '\0')
        path = "/";

    hd_fill_object_info(file, path, NULL, NULL, file->fileID, &info, errorMessage);
    return info;
}

typedef struct {
    HDHDFFile *file;
    const char *parentPath;
    hid_t parentID;
    HDHDFObjectInfo *items;
    size_t count;
    size_t capacity;
    char *errorMessage;
} HDChildrenContext;

static bool hd_children_append(HDChildrenContext *context, HDHDFObjectInfo info)
{
    if (context->count == context->capacity) {
        size_t nextCapacity = context->capacity == 0 ? 16 : context->capacity * 2;
        HDHDFObjectInfo *next = (HDHDFObjectInfo *)realloc(context->items, nextCapacity * sizeof(HDHDFObjectInfo));
        if (next == NULL)
            return false;
        context->items = next;
        context->capacity = nextCapacity;
    }

    context->items[context->count++] = info;
    return true;
}

static herr_t hd_iterate_child(hid_t groupID, const char *name, const H5L_info2_t *linkInfo, void *opData)
{
    HDChildrenContext *context = (HDChildrenContext *)opData;
    char *childPath = hd_join_path(context->parentPath, name);
    if (childPath == NULL) {
        context->errorMessage = hd_copy_string("Out of memory while reading child paths");
        return -1;
    }

    HDHDFObjectInfo item;
    char *errorMessage = NULL;
    bool didFill = hd_fill_object_info(context->file, childPath, name, linkInfo, groupID, &item, &errorMessage);
    free(childPath);

    if (!didFill) {
        context->errorMessage = errorMessage == NULL ? hd_copy_string("Could not inspect a child object") : errorMessage;
        return -1;
    }

    if (!hd_children_append(context, item)) {
        HDHDFFreeObjectInfo(&item);
        context->errorMessage = hd_copy_string("Out of memory while reading child objects");
        return -1;
    }

    return 0;
}

HDHDFObjectList HDHDFCopyChildren(HDHDFFile *file, const char *groupPath)
{
    HDHDFObjectList list;
    memset(&list, 0, sizeof(list));

    if (file == NULL) {
        list.errorMessage = hd_copy_string("No HDF5 file is open");
        return list;
    }

    if (groupPath == NULL || groupPath[0] == '\0')
        groupPath = "/";

    hid_t groupID = H5Gopen2(file->fileID, groupPath, H5P_DEFAULT);
    if (groupID < 0) {
        list.errorMessage = hd_format_string("Could not open group %s", groupPath);
        return list;
    }

    HDChildrenContext context = {
        .file = file,
        .parentPath = groupPath,
        .parentID = groupID,
        .items = NULL,
        .count = 0,
        .capacity = 0,
        .errorMessage = NULL
    };

    hsize_t index = 0;
    herr_t status = H5Literate2(groupID, H5_INDEX_NAME, H5_ITER_INC, &index, hd_iterate_child, &context);
    H5Gclose(groupID);

    list.items = context.items;
    list.count = context.count;
    if (status < 0)
        list.errorMessage = context.errorMessage == NULL ? hd_copy_string("Could not read group children") : context.errorMessage;

    return list;
}

static hsize_t hd_dataspace_element_count(hid_t dataspaceID)
{
    H5S_class_t spaceClass = H5Sget_simple_extent_type(dataspaceID);
    if (spaceClass == H5S_NULL)
        return 0;
    if (spaceClass == H5S_SCALAR)
        return 1;

    hssize_t points = H5Sget_simple_extent_npoints(dataspaceID);
    return points < 0 ? 0 : (hsize_t)points;
}

typedef enum {
    HDCompoundValueSignedInteger,
    HDCompoundValueUnsignedInteger,
    HDCompoundValueFloat
} HDCompoundValueKind;

typedef struct {
    char *name;
    hid_t nativeTypeID;
    size_t offset;
    size_t size;
    int roundtripPrecision;
    int displayPrecision;
    HDCompoundValueKind valueKind;
} HDCompoundColumn;

static bool hd_compound_member_memory_type(hid_t memberTypeID,
                                           HDCompoundValueKind *valueKind,
                                           hid_t *nativeTypeID,
                                           size_t *size,
                                           int *roundtripPrecision,
                                           int *displayPrecision)
{
    H5T_class_t typeClass = H5Tget_class(memberTypeID);
    if (typeClass == H5T_INTEGER) {
        if (H5Tget_sign(memberTypeID) == H5T_SGN_NONE) {
            *valueKind = HDCompoundValueUnsignedInteger;
            *nativeTypeID = H5T_NATIVE_ULLONG;
            *size = sizeof(unsigned long long);
        } else {
            *valueKind = HDCompoundValueSignedInteger;
            *nativeTypeID = H5T_NATIVE_LLONG;
            *size = sizeof(long long);
        }
        *roundtripPrecision = 0;
        *displayPrecision = 0;
        return true;
    }

    if (typeClass == H5T_FLOAT) {
        *valueKind = HDCompoundValueFloat;
        *nativeTypeID = H5T_NATIVE_DOUBLE;
        *size = sizeof(double);
        *roundtripPrecision = hd_float_roundtrip_digits(memberTypeID);
        *displayPrecision = hd_float_display_precision(memberTypeID);
        return true;
    }

    return false;
}

static void hd_free_compound_columns(HDCompoundColumn *columns, size_t count)
{
    if (columns == NULL)
        return;

    for (size_t index = 0; index < count; index++)
        free(columns[index].name);
    free(columns);
}

static bool hd_copy_compound_columns(hid_t fileTypeID,
                                     uint64_t maxColumns,
                                     HDCompoundColumn **columns,
                                     size_t *columnCount,
                                     size_t *recordSize)
{
    *columns = NULL;
    *columnCount = 0;
    *recordSize = 0;

    int memberCount = H5Tget_nmembers(fileTypeID);
    if (memberCount <= 0 || maxColumns == 0)
        return false;

    size_t capacity = (size_t)((uint64_t)memberCount < maxColumns ? (uint64_t)memberCount : maxColumns);
    HDCompoundColumn *items = (HDCompoundColumn *)calloc(capacity, sizeof(HDCompoundColumn));
    if (items == NULL)
        return false;

    for (int memberIndex = 0; memberIndex < memberCount && *columnCount < capacity; memberIndex++) {
        hid_t memberTypeID = H5Tget_member_type(fileTypeID, (unsigned)memberIndex);
        if (memberTypeID < 0)
            continue;

        HDCompoundValueKind valueKind = HDCompoundValueSignedInteger;
        hid_t nativeTypeID = -1;
        size_t size = 0;
        int roundtripPrecision = 0;
        int displayPrecision = 0;
        bool isSupported = hd_compound_member_memory_type(memberTypeID,
                                                          &valueKind,
                                                          &nativeTypeID,
                                                          &size,
                                                          &roundtripPrecision,
                                                          &displayPrecision);
        H5Tclose(memberTypeID);
        if (!isSupported)
            continue;

        char *memberName = H5Tget_member_name(fileTypeID, (unsigned)memberIndex);
        if (memberName == NULL)
            continue;

        char *name = hd_copy_string(memberName);
        H5free_memory(memberName);
        if (name == NULL) {
            hd_free_compound_columns(items, *columnCount);
            return false;
        }

        items[*columnCount].name = name;
        items[*columnCount].nativeTypeID = nativeTypeID;
        items[*columnCount].offset = *recordSize;
        items[*columnCount].size = size;
        items[*columnCount].roundtripPrecision = roundtripPrecision;
        items[*columnCount].displayPrecision = displayPrecision;
        items[*columnCount].valueKind = valueKind;
        *recordSize += size;
        *columnCount += 1;
    }

    if (*columnCount == 0) {
        free(items);
        return false;
    }

    *columns = items;
    return true;
}

static uint64_t hd_compound_supported_column_count(hid_t fileTypeID, uint64_t maxColumns)
{
    HDCompoundColumn *columns = NULL;
    size_t columnCount = 0;
    size_t recordSize = 0;
    if (!hd_copy_compound_columns(fileTypeID, maxColumns, &columns, &columnCount, &recordSize))
        return 0;

    hd_free_compound_columns(columns, columnCount);
    return (uint64_t)columnCount;
}

static bool hd_read_compound_values_into_builder(hid_t readerID,
                                                 hid_t fileTypeID,
                                                 hid_t fileSpaceID,
                                                 hid_t memorySpaceID,
                                                 uint64_t rowCount,
                                                 uint64_t columnCount,
                                                 HDStringBuilder *builder,
                                                 char **columnLabels,
                                                 char **columnDisplayPrecisions)
{
    HDCompoundColumn *columns = NULL;
    size_t actualColumnCount = 0;
    size_t recordSize = 0;
    if (!hd_copy_compound_columns(fileTypeID, columnCount, &columns, &actualColumnCount, &recordSize))
        return false;

    hid_t memoryTypeID = H5Tcreate(H5T_COMPOUND, recordSize);
    if (memoryTypeID < 0) {
        hd_free_compound_columns(columns, actualColumnCount);
        return false;
    }

    for (size_t columnIndex = 0; columnIndex < actualColumnCount; columnIndex++) {
        if (H5Tinsert(memoryTypeID,
                      columns[columnIndex].name,
                      columns[columnIndex].offset,
                      columns[columnIndex].nativeTypeID) < 0) {
            H5Tclose(memoryTypeID);
            hd_free_compound_columns(columns, actualColumnCount);
            return false;
        }
    }

    char *values = (char *)calloc((size_t)rowCount, recordSize);
    if (values == NULL) {
        H5Tclose(memoryTypeID);
        hd_free_compound_columns(columns, actualColumnCount);
        return false;
    }

    herr_t readStatus = H5Dread(readerID, memoryTypeID, memorySpaceID, fileSpaceID, H5P_DEFAULT, values);
    if (readStatus < 0) {
        free(values);
        H5Tclose(memoryTypeID);
        hd_free_compound_columns(columns, actualColumnCount);
        return false;
    }

    for (uint64_t row = 0; row < rowCount; row++) {
        if (row > 0)
            hd_sb_append(builder, "\n");

        const char *record = values + ((size_t)row * recordSize);
        for (size_t columnIndex = 0; columnIndex < actualColumnCount; columnIndex++) {
            if (columnIndex > 0)
                hd_sb_append(builder, "\t");

            const char *cell = record + columns[columnIndex].offset;
            switch (columns[columnIndex].valueKind) {
            case HDCompoundValueSignedInteger: {
                long long value = 0;
                memcpy(&value, cell, sizeof(value));
                hd_sb_appendf(builder, "%lld", value);
                break;
            }
            case HDCompoundValueUnsignedInteger: {
                unsigned long long value = 0;
                memcpy(&value, cell, sizeof(value));
                hd_sb_appendf(builder, "%llu", value);
                break;
            }
            case HDCompoundValueFloat: {
                double value = 0;
                memcpy(&value, cell, sizeof(value));
                hd_append_floating_value(builder, value, columns[columnIndex].roundtripPrecision);
                break;
            }
            }
        }
    }

    if (columnLabels != NULL) {
        HDStringBuilder labels = {0};
        for (size_t columnIndex = 0; columnIndex < actualColumnCount; columnIndex++) {
            if (columnIndex > 0)
                hd_sb_append(&labels, "\t");
            hd_sb_append(&labels, columns[columnIndex].name);
        }
        *columnLabels = hd_sb_finish(&labels);
    }

    if (columnDisplayPrecisions != NULL) {
        HDStringBuilder precisions = {0};
        for (size_t columnIndex = 0; columnIndex < actualColumnCount; columnIndex++) {
            if (columnIndex > 0)
                hd_sb_append(&precisions, "\t");
            hd_sb_appendf(&precisions, "%d", columns[columnIndex].displayPrecision);
        }
        *columnDisplayPrecisions = hd_sb_finish(&precisions);
    }

    free(values);
    H5Tclose(memoryTypeID);
    hd_free_compound_columns(columns, actualColumnCount);
    return true;
}

static bool hd_read_values_into_builder(hid_t readerID,
                                        hid_t fileTypeID,
                                        hid_t fileSpaceID,
                                        hid_t memorySpaceID,
                                        bool isAttribute,
                                        uint64_t rowCount,
                                        uint64_t columnCount,
                                        uint64_t valueCount,
                                        HDStringBuilder *builder,
                                        char **columnLabels,
                                        char **columnDisplayPrecisions)
{
    H5T_class_t typeClass = H5Tget_class(fileTypeID);

    if (typeClass == H5T_COMPOUND && !isAttribute) {
        return hd_read_compound_values_into_builder(readerID,
                                                    fileTypeID,
                                                    fileSpaceID,
                                                    memorySpaceID,
                                                    rowCount,
                                                    columnCount,
                                                    builder,
                                                    columnLabels,
                                                    columnDisplayPrecisions);
    }

    if (typeClass == H5T_INTEGER) {
        if (columnDisplayPrecisions != NULL)
            *columnDisplayPrecisions = hd_copy_repeated_precision_list(0, columnCount);
        H5T_sign_t sign = H5Tget_sign(fileTypeID);
        if (sign == H5T_SGN_NONE) {
            unsigned long long *values = (unsigned long long *)calloc((size_t)valueCount, sizeof(unsigned long long));
            if (values == NULL)
                return false;
            herr_t readStatus = isAttribute
                ? H5Aread(readerID, H5T_NATIVE_ULLONG, values)
                : H5Dread(readerID, H5T_NATIVE_ULLONG, memorySpaceID, fileSpaceID, H5P_DEFAULT, values);
            if (readStatus < 0) {
                free(values);
                return false;
            }
            for (uint64_t index = 0; index < valueCount; index++) {
                if (index > 0)
                    hd_sb_append(builder, index % columnCount == 0 ? "\n" : "\t");
                hd_sb_appendf(builder, "%llu", values[index]);
            }
            free(values);
            return true;
        }

        long long *values = (long long *)calloc((size_t)valueCount, sizeof(long long));
        if (values == NULL)
            return false;
        herr_t readStatus = isAttribute
            ? H5Aread(readerID, H5T_NATIVE_LLONG, values)
            : H5Dread(readerID, H5T_NATIVE_LLONG, memorySpaceID, fileSpaceID, H5P_DEFAULT, values);
        if (readStatus < 0) {
            free(values);
            return false;
        }
        for (uint64_t index = 0; index < valueCount; index++) {
            if (index > 0)
                hd_sb_append(builder, index % columnCount == 0 ? "\n" : "\t");
            hd_sb_appendf(builder, "%lld", values[index]);
        }
        free(values);
        return true;
    }

    if (typeClass == H5T_FLOAT) {
        int roundtripPrecision = hd_float_roundtrip_digits(fileTypeID);
        if (columnDisplayPrecisions != NULL)
            *columnDisplayPrecisions = hd_copy_repeated_precision_list(
                hd_float_display_precision(fileTypeID),
                columnCount
            );
        double *values = (double *)calloc((size_t)valueCount, sizeof(double));
        if (values == NULL)
            return false;
        herr_t readStatus = isAttribute
            ? H5Aread(readerID, H5T_NATIVE_DOUBLE, values)
            : H5Dread(readerID, H5T_NATIVE_DOUBLE, memorySpaceID, fileSpaceID, H5P_DEFAULT, values);
        if (readStatus < 0) {
            free(values);
            return false;
        }
        for (uint64_t index = 0; index < valueCount; index++) {
            if (index > 0)
                hd_sb_append(builder, index % columnCount == 0 ? "\n" : "\t");
            hd_append_floating_value(builder, values[index], roundtripPrecision);
        }
        free(values);
        return true;
    }

    if (typeClass == H5T_STRING) {
        if (H5Tis_variable_str(fileTypeID) > 0) {
            char **values = (char **)calloc((size_t)valueCount, sizeof(char *));
            hid_t memoryTypeID = H5Tcopy(H5T_C_S1);
            if (values == NULL || memoryTypeID < 0) {
                free(values);
                if (memoryTypeID >= 0)
                    H5Tclose(memoryTypeID);
                return false;
            }
            H5Tset_size(memoryTypeID, H5T_VARIABLE);
            H5Tset_cset(memoryTypeID, H5Tget_cset(fileTypeID));
            herr_t readStatus = isAttribute
                ? H5Aread(readerID, memoryTypeID, values)
                : H5Dread(readerID, memoryTypeID, memorySpaceID, fileSpaceID, H5P_DEFAULT, values);
            if (readStatus < 0) {
                H5Tclose(memoryTypeID);
                free(values);
                return false;
            }
            for (uint64_t index = 0; index < valueCount; index++) {
                if (index > 0)
                    hd_sb_append(builder, index % columnCount == 0 ? "\n" : "\t");
                hd_sb_append(builder, values[index] == NULL ? "" : values[index]);
            }
            H5Treclaim(memoryTypeID, memorySpaceID, H5P_DEFAULT, values);
            H5Tclose(memoryTypeID);
            free(values);
            return true;
        }

        size_t width = H5Tget_size(fileTypeID);
        char *values = (char *)calloc((size_t)valueCount, width + 1);
        if (values == NULL)
            return false;
        herr_t readStatus = isAttribute
            ? H5Aread(readerID, fileTypeID, values)
            : H5Dread(readerID, fileTypeID, memorySpaceID, fileSpaceID, H5P_DEFAULT, values);
        if (readStatus < 0) {
            free(values);
            return false;
        }
        for (uint64_t index = 0; index < valueCount; index++) {
            if (index > 0)
                hd_sb_append(builder, index % columnCount == 0 ? "\n" : "\t");
            char *cell = values + (index * width);
            size_t actualWidth = strnlen(cell, width);
            hd_sb_append_bytes(builder, cell, actualWidth);
        }
        free(values);
        return true;
    }

    return false;
}

static bool hd_read_numeric_scalar_attribute(hid_t objectID, const char *name, double *value)
{
    if (objectID < 0 || name == NULL || value == NULL)
        return false;

    htri_t exists = H5Aexists(objectID, name);
    if (exists <= 0)
        return false;

    hid_t attributeID = H5Aopen(objectID, name, H5P_DEFAULT);
    if (attributeID < 0)
        return false;

    hid_t typeID = H5Aget_type(attributeID);
    hid_t spaceID = H5Aget_space(attributeID);
    bool didRead = false;

    if (typeID >= 0 && spaceID >= 0 && hd_dataspace_element_count(spaceID) == 1) {
        H5T_class_t typeClass = H5Tget_class(typeID);
        if (typeClass == H5T_FLOAT) {
            double raw = 0;
            if (H5Aread(attributeID, H5T_NATIVE_DOUBLE, &raw) >= 0) {
                *value = raw;
                didRead = true;
            }
        } else if (typeClass == H5T_INTEGER) {
            if (H5Tget_sign(typeID) == H5T_SGN_NONE) {
                unsigned long long raw = 0;
                if (H5Aread(attributeID, H5T_NATIVE_ULLONG, &raw) >= 0) {
                    *value = (double)raw;
                    didRead = true;
                }
            } else {
                long long raw = 0;
                if (H5Aread(attributeID, H5T_NATIVE_LLONG, &raw) >= 0) {
                    *value = (double)raw;
                    didRead = true;
                }
            }
        } else if (typeClass == H5T_STRING) {
            if (H5Tis_variable_str(typeID) > 0) {
                char *raw = NULL;
                hid_t memoryTypeID = H5Tcopy(H5T_C_S1);
                if (memoryTypeID >= 0) {
                    H5Tset_size(memoryTypeID, H5T_VARIABLE);
                    if (H5Aread(attributeID, memoryTypeID, &raw) >= 0 && raw != NULL) {
                        char *end = NULL;
                        double parsed = strtod(raw, &end);
                        if (end != raw) {
                            *value = parsed;
                            didRead = true;
                        }
                        H5Treclaim(memoryTypeID, spaceID, H5P_DEFAULT, &raw);
                    }
                    H5Tclose(memoryTypeID);
                }
            } else {
                size_t width = H5Tget_size(typeID);
                char *raw = (char *)calloc(width + 1, 1);
                if (raw != NULL) {
                    if (H5Aread(attributeID, typeID, raw) >= 0) {
                        char *end = NULL;
                        double parsed = strtod(raw, &end);
                        if (end != raw) {
                            *value = parsed;
                            didRead = true;
                        }
                    }
                    free(raw);
                }
            }
        }
    }

    if (spaceID >= 0)
        H5Sclose(spaceID);
    if (typeID >= 0)
        H5Tclose(typeID);
    H5Aclose(attributeID);
    return didRead;
}

static bool hd_find_numeric_attribute(hid_t primaryID,
                                      hid_t fallbackID,
                                      const char *name,
                                      double *value)
{
    if (hd_read_numeric_scalar_attribute(primaryID, name, value))
        return true;
    return hd_read_numeric_scalar_attribute(fallbackID, name, value);
}

static bool hd_finish_generated_time_axis(uint64_t startRow,
                                          uint64_t rowCount,
                                          uint64_t rowStride,
                                          double samplingRate,
                                          double startTime,
                                          HDStringBuilder *builder)
{
    if (rowCount == 0 || samplingRate <= 0)
        return false;
    if (rowStride == 0)
        rowStride = 1;

    for (uint64_t row = 0; row < rowCount; row++) {
        if (row > 0)
            hd_sb_append(builder, "\t");
        double value = startTime + ((double)(startRow + (row * rowStride)) / samplingRate);
        hd_append_floating_value(builder, value, DBL_DECIMAL_DIG);
    }
    return true;
}

static bool hd_copy_attribute_time_axis(HDHDFFile *file,
                                        hid_t datasetID,
                                        const char *datasetPath,
                                        uint64_t startRow,
                                        uint64_t rowCount,
                                        uint64_t rowStride,
                                        char **values,
                                        char **label,
                                        char **source,
                                        int *displayPrecision)
{
    if (values == NULL || label == NULL || source == NULL)
        return false;

    *values = NULL;
    *label = NULL;
    *source = NULL;

    char *parentPath = hd_parent_path(datasetPath);
    hid_t parentID = -1;
    if (file != NULL && parentPath != NULL)
        parentID = H5Gopen2(file->fileID, parentPath, H5P_DEFAULT);

    double samplingRate = 0;
    if (!hd_find_numeric_attribute(datasetID, parentID, "sampling_rate", &samplingRate) || samplingRate <= 0) {
        if (parentID >= 0)
            H5Gclose(parentID);
        free(parentPath);
        return false;
    }

    double startTime = 0;
    hd_find_numeric_attribute(datasetID, parentID, "start_time", &startTime);

    HDStringBuilder builder = {0};
    bool didBuild = hd_finish_generated_time_axis(startRow, rowCount, rowStride, samplingRate, startTime, &builder);
    if (!didBuild) {
        hd_sb_dispose(&builder);
        if (parentID >= 0)
            H5Gclose(parentID);
        free(parentPath);
        return false;
    }

    *values = hd_sb_finish(&builder);
    *label = hd_copy_string("time");
    *source = hd_copy_string("sampling_rate/start_time");
    if (displayPrecision != NULL)
        *displayPrecision = DBL_DECIMAL_DIG;

    if (parentID >= 0)
        H5Gclose(parentID);
    free(parentPath);
    return true;
}

static bool hd_read_axis_dataset_values(hid_t axisDatasetID,
                                        uint64_t startRow,
                                        uint64_t rowCount,
                                        uint64_t rowStride,
                                        char **values,
                                        int *displayPrecision)
{
    if (axisDatasetID < 0 || rowCount == 0 || values == NULL)
        return false;
    if (rowStride == 0)
        rowStride = 1;

    *values = NULL;

    hid_t typeID = H5Dget_type(axisDatasetID);
    hid_t spaceID = H5Dget_space(axisDatasetID);
    if (typeID < 0 || spaceID < 0) {
        if (typeID >= 0)
            H5Tclose(typeID);
        if (spaceID >= 0)
            H5Sclose(spaceID);
        return false;
    }

    bool didRead = false;
    int rank = H5Sget_simple_extent_ndims(spaceID);
    if (rank == 1) {
        hsize_t dims[1] = {0};
        H5Sget_simple_extent_dims(spaceID, dims, NULL);
        if (startRow < (uint64_t)dims[0]) {
            uint64_t availableRows = (uint64_t)dims[0] - startRow;
            uint64_t stridedRows = ((availableRows - 1) / rowStride) + 1;
            uint64_t rows = stridedRows < rowCount ? stridedRows : rowCount;
            if (rows == rowCount) {
                hsize_t start[1] = {(hsize_t)startRow};
                hsize_t stride[1] = {(hsize_t)rowStride};
                hsize_t count[1] = {(hsize_t)rows};
                if (H5Sselect_hyperslab(spaceID, H5S_SELECT_SET, start, stride, count, NULL) >= 0) {
                    hid_t memorySpaceID = H5Screate_simple(1, count, NULL);
                    if (memorySpaceID >= 0) {
                        HDStringBuilder builder = {0};
                        char *unusedPrecisions = NULL;
                        didRead = hd_read_values_into_builder(axisDatasetID,
                                                              typeID,
                                                              spaceID,
                                                              memorySpaceID,
                                                              false,
                                                              rows,
                                                              1,
                                                              rows,
                                                              &builder,
                                                              NULL,
                                                              &unusedPrecisions);
                        if (didRead) {
                            *values = hd_sb_finish(&builder);
                            // The shared reader emits one value per line for a single
                            // column, but xAxisValues is a flat tab-separated vector.
                            for (char *c = *values; c != NULL && *c != '\0'; c++) {
                                if (*c == '\n')
                                    *c = '\t';
                            }
                            if (displayPrecision != NULL) {
                                if (unusedPrecisions != NULL)
                                    *displayPrecision = atoi(unusedPrecisions);
                                else if (H5Tget_class(typeID) == H5T_FLOAT)
                                    *displayPrecision = hd_float_display_precision(typeID);
                                else
                                    *displayPrecision = 0;
                            }
                        } else {
                            hd_sb_dispose(&builder);
                        }
                        free(unusedPrecisions);
                        H5Sclose(memorySpaceID);
                    }
                }
            }
        }
    }

    H5Sclose(spaceID);
    H5Tclose(typeID);
    return didRead;
}

static bool hd_copy_named_time_axis(HDHDFFile *file,
                                    const char *datasetPath,
                                    uint64_t startRow,
                                    uint64_t rowCount,
                                    uint64_t rowStride,
                                    char **values,
                                    char **label,
                                    char **source,
                                    int *displayPrecision)
{
    if (file == NULL || values == NULL || label == NULL || source == NULL)
        return false;

    *values = NULL;
    *label = NULL;
    *source = NULL;

    char *parentPath = hd_parent_path(datasetPath);
    char *timePath = hd_join_path(parentPath, "time");
    if (timePath == NULL) {
        free(parentPath);
        return false;
    }

    hid_t timeDatasetID = H5Dopen2(file->fileID, timePath, H5P_DEFAULT);
    if (timeDatasetID < 0) {
        free(timePath);
        free(parentPath);
        return false;
    }

    bool didRead = hd_read_axis_dataset_values(timeDatasetID,
                                               startRow,
                                               rowCount,
                                               rowStride,
                                               values,
                                               displayPrecision);
    if (didRead) {
        *label = hd_copy_string("time");
        *source = hd_copy_string("time");
    }

    H5Dclose(timeDatasetID);
    free(timePath);
    free(parentPath);
    return didRead;
}

static char *hd_copy_axis_label_from_dataset(hid_t axisDatasetID, const char *fallback)
{
    if (axisDatasetID < 0)
        return hd_copy_string(fallback == NULL ? "axis" : fallback);

    htri_t exists = H5Aexists(axisDatasetID, "NAME");
    if (exists > 0) {
        hid_t attributeID = H5Aopen(axisDatasetID, "NAME", H5P_DEFAULT);
        hid_t typeID = attributeID < 0 ? -1 : H5Aget_type(attributeID);
        hid_t spaceID = attributeID < 0 ? -1 : H5Aget_space(attributeID);
        if (attributeID >= 0 && typeID >= 0 && spaceID >= 0 && H5Tget_class(typeID) == H5T_STRING) {
            if (H5Tis_variable_str(typeID) > 0) {
                char *raw = NULL;
                hid_t memoryTypeID = H5Tcopy(H5T_C_S1);
                if (memoryTypeID >= 0) {
                    H5Tset_size(memoryTypeID, H5T_VARIABLE);
                    if (H5Aread(attributeID, memoryTypeID, &raw) >= 0 && raw != NULL) {
                        char *copy = hd_copy_string(raw);
                        H5Treclaim(memoryTypeID, spaceID, H5P_DEFAULT, &raw);
                        H5Tclose(memoryTypeID);
                        H5Sclose(spaceID);
                        H5Tclose(typeID);
                        H5Aclose(attributeID);
                        return copy;
                    }
                    H5Tclose(memoryTypeID);
                }
            } else {
                size_t width = H5Tget_size(typeID);
                char *raw = (char *)calloc(width + 1, 1);
                if (raw != NULL) {
                    if (H5Aread(attributeID, typeID, raw) >= 0) {
                        char *copy = hd_copy_string(raw);
                        free(raw);
                        H5Sclose(spaceID);
                        H5Tclose(typeID);
                        H5Aclose(attributeID);
                        return copy;
                    }
                    free(raw);
                }
            }
        }
        if (spaceID >= 0)
            H5Sclose(spaceID);
        if (typeID >= 0)
            H5Tclose(typeID);
        if (attributeID >= 0)
            H5Aclose(attributeID);
    }

    return hd_copy_string(fallback == NULL ? "axis" : fallback);
}

static bool hd_copy_dimension_scale_axis(hid_t datasetID,
                                         uint64_t startRow,
                                         uint64_t rowCount,
                                         uint64_t rowStride,
                                         char **values,
                                         char **label,
                                         char **source,
                                         int *displayPrecision)
{
    if (datasetID < 0 || values == NULL || label == NULL || source == NULL)
        return false;

    *values = NULL;
    *label = NULL;
    *source = NULL;

    htri_t exists = H5Aexists(datasetID, "DIMENSION_LIST");
    if (exists <= 0)
        return false;

    hid_t attributeID = H5Aopen(datasetID, "DIMENSION_LIST", H5P_DEFAULT);
    hid_t typeID = attributeID < 0 ? -1 : H5Aget_type(attributeID);
    hid_t spaceID = attributeID < 0 ? -1 : H5Aget_space(attributeID);
    bool didRead = false;

    if (attributeID >= 0 && typeID >= 0 && spaceID >= 0 && H5Tget_class(typeID) == H5T_VLEN) {
        hssize_t pointCount = H5Sget_simple_extent_npoints(spaceID);
        if (pointCount > 0) {
            hvl_t *lists = (hvl_t *)calloc((size_t)pointCount, sizeof(hvl_t));
            if (lists != NULL && H5Aread(attributeID, typeID, lists) >= 0) {
                if (lists[0].len > 0 && lists[0].p != NULL) {
                    const hobj_ref_t *refs = (const hobj_ref_t *)lists[0].p;
                    hid_t axisDatasetID = H5Rdereference2(datasetID, H5P_DEFAULT, H5R_OBJECT, &refs[0]);
                    if (axisDatasetID >= 0) {
                        didRead = hd_read_axis_dataset_values(axisDatasetID,
                                                             startRow,
                                                             rowCount,
                                                             rowStride,
                                                             values,
                                                             displayPrecision);
                        if (didRead) {
                            *label = hd_copy_axis_label_from_dataset(axisDatasetID, "Dimension Scale");
                            *source = hd_copy_string("dimension scale");
                        }
                        H5Dclose(axisDatasetID);
                    }
                }
                H5Treclaim(typeID, spaceID, H5P_DEFAULT, lists);
            }
            free(lists);
        }
    }

    if (spaceID >= 0)
        H5Sclose(spaceID);
    if (typeID >= 0)
        H5Tclose(typeID);
    if (attributeID >= 0)
        H5Aclose(attributeID);
    return didRead;
}

static void hd_copy_preview_x_axis(HDHDFFile *file,
                                   hid_t datasetID,
                                   const char *datasetPath,
                                   uint64_t startRow,
                                   uint64_t rowCount,
                                   uint64_t rowStride,
                                   char **values,
                                   char **label,
                                   char **source,
                                   int *displayPrecision)
{
    if (values == NULL || label == NULL || source == NULL)
        return;

    *values = NULL;
    *label = NULL;
    *source = NULL;
    if (displayPrecision != NULL)
        *displayPrecision = 0;

    if (hd_copy_named_time_axis(file, datasetPath, startRow, rowCount, rowStride, values, label, source, displayPrecision))
        return;
    if (hd_copy_attribute_time_axis(file, datasetID, datasetPath, startRow, rowCount, rowStride, values, label, source, displayPrecision))
        return;
    if (hd_copy_dimension_scale_axis(datasetID, startRow, rowCount, rowStride, values, label, source, displayPrecision))
        return;

    *values = hd_copy_string("");
    *label = hd_copy_string("");
    *source = hd_copy_string("");
}

typedef struct {
    HDHDFAttributeInfo *items;
    size_t count;
    size_t capacity;
    size_t valueByteLimit;
    char *errorMessage;
} HDAttributeContext;

static bool hd_attribute_append(HDAttributeContext *context, HDHDFAttributeInfo item)
{
    if (context->count == context->capacity) {
        size_t nextCapacity = context->capacity == 0 ? 8 : context->capacity * 2;
        HDHDFAttributeInfo *next = (HDHDFAttributeInfo *)realloc(context->items, nextCapacity * sizeof(HDHDFAttributeInfo));
        if (next == NULL)
            return false;
        context->items = next;
        context->capacity = nextCapacity;
    }

    context->items[context->count++] = item;
    return true;
}

static herr_t hd_iterate_attribute(hid_t objectID, const char *name, const H5A_info_t *attributeInfo, void *opData)
{
    (void)attributeInfo;

    HDAttributeContext *context = (HDAttributeContext *)opData;
    HDHDFAttributeInfo item;
    memset(&item, 0, sizeof(item));
    item.name = hd_copy_string(name);
    item.valuePreview = hd_copy_string("");

    hid_t attributeID = H5Aopen(objectID, name, H5P_DEFAULT);
    if (attributeID < 0) {
        context->errorMessage = hd_format_string("Could not open attribute %s", name);
        return -1;
    }

    hid_t typeID = H5Aget_type(attributeID);
    hid_t spaceID = H5Aget_space(attributeID);

    if (typeID >= 0)
        item.typeDescription = hd_copy_datatype_description(typeID);
    if (spaceID >= 0)
        item.shapeDescription = hd_copy_shape_description(spaceID);

    if (typeID >= 0 && spaceID >= 0) {
        hsize_t elementCount = hd_dataspace_element_count(spaceID);
        bool mayPreview = hd_can_preview_attribute_value(typeID, elementCount, context->valueByteLimit);

        if (mayPreview) {
            HDStringBuilder builder = {0};
            if (hd_read_values_into_builder(attributeID,
                                            typeID,
                                            spaceID,
                                            spaceID,
                                            true,
                                            1,
                                            elementCount,
                                            elementCount,
                                            &builder,
                                            NULL,
                                            NULL)) {
                free(item.valuePreview);
                item.valuePreview = hd_sb_finish(&builder);
            } else {
                hd_sb_dispose(&builder);
                free(item.valuePreview);
                item.valuePreview = hd_copy_string("Preview unavailable for this attribute type");
            }
        } else if (elementCount > 0) {
            item.isValueTruncated = true;
            free(item.valuePreview);
            item.valuePreview = hd_format_string("%llu values", (unsigned long long)elementCount);
        }
    }

    if (typeID >= 0)
        H5Tclose(typeID);
    if (spaceID >= 0)
        H5Sclose(spaceID);
    H5Aclose(attributeID);

    if (!hd_attribute_append(context, item)) {
        free(item.name);
        free(item.typeDescription);
        free(item.shapeDescription);
        free(item.valuePreview);
        context->errorMessage = hd_copy_string("Out of memory while reading attributes");
        return -1;
    }

    return 0;
}

HDHDFAttributeList HDHDFCopyAttributes(HDHDFFile *file, const char *objectPath, size_t valueByteLimit)
{
    HDHDFAttributeList list;
    memset(&list, 0, sizeof(list));

    if (file == NULL) {
        list.errorMessage = hd_copy_string("No HDF5 file is open");
        return list;
    }

    if (objectPath == NULL || objectPath[0] == '\0')
        objectPath = "/";

    hid_t objectID = H5Oopen(file->fileID, objectPath, H5P_DEFAULT);
    if (objectID < 0) {
        list.errorMessage = hd_format_string("Could not open object %s", objectPath);
        return list;
    }

    HDAttributeContext context = {
        .items = NULL,
        .count = 0,
        .capacity = 0,
        .valueByteLimit = valueByteLimit == 0 ? 4096 : valueByteLimit,
        .errorMessage = NULL
    };

    hsize_t index = 0;
    herr_t status = H5Aiterate2(objectID, H5_INDEX_NAME, H5_ITER_INC, &index, hd_iterate_attribute, &context);
    H5Oclose(objectID);

    list.items = context.items;
    list.count = context.count;
    if (status < 0)
        list.errorMessage = context.errorMessage == NULL ? hd_copy_string("Could not read object attributes") : context.errorMessage;

    return list;
}

static bool hd_mul_would_overflow(uint64_t lhs, uint64_t rhs)
{
    return rhs != 0 && lhs > UINT64_MAX / rhs;
}

static HDHDFDatasetPreview hd_copy_dataset_preview_window(HDHDFFile *file,
                                                          const char *datasetPath,
                                                          uint64_t startRow,
                                                          uint64_t maxRows,
                                                          uint64_t maxColumns,
                                                          uint64_t maxScalarValues,
                                                          bool sampleFullRange,
                                                          uint64_t sampleRowCount,
                                                          const uint64_t *sliceStarts,
                                                          size_t sliceCount)
{
    HDHDFDatasetPreview preview;
    memset(&preview, 0, sizeof(preview));

    if (file == NULL) {
        preview.errorMessage = hd_copy_string("No HDF5 file is open");
        return preview;
    }

    if (datasetPath == NULL || datasetPath[0] == '\0') {
        preview.errorMessage = hd_copy_string("No dataset path was provided");
        return preview;
    }

    if (maxRows == 0)
        maxRows = 200;
    if (maxColumns == 0)
        maxColumns = 32;
    if (maxScalarValues == 0)
        maxScalarValues = 4096;

    hid_t datasetID = H5Dopen2(file->fileID, datasetPath, H5P_DEFAULT);
    if (datasetID < 0) {
        preview.errorMessage = hd_format_string("Could not open dataset %s", datasetPath);
        return preview;
    }

    hid_t fileTypeID = H5Dget_type(datasetID);
    hid_t fileSpaceID = H5Dget_space(datasetID);
    if (fileTypeID < 0 || fileSpaceID < 0) {
        preview.errorMessage = hd_format_string("Could not inspect dataset %s", datasetPath);
        if (fileTypeID >= 0)
            H5Tclose(fileTypeID);
        if (fileSpaceID >= 0)
            H5Sclose(fileSpaceID);
        H5Dclose(datasetID);
        return preview;
    }

    int rank = H5Sget_simple_extent_ndims(fileSpaceID);
    if (rank < 0) {
        preview.errorMessage = hd_copy_string("Could not inspect dataset dimensions");
        H5Sclose(fileSpaceID);
        H5Tclose(fileTypeID);
        H5Dclose(datasetID);
        return preview;
    }

    hsize_t *dims = rank == 0 ? NULL : (hsize_t *)calloc((size_t)rank, sizeof(hsize_t));
    hsize_t *start = rank == 0 ? NULL : (hsize_t *)calloc((size_t)rank, sizeof(hsize_t));
    hsize_t *selectionStride = rank == 0 ? NULL : (hsize_t *)calloc((size_t)rank, sizeof(hsize_t));
    hsize_t *count = rank == 0 ? NULL : (hsize_t *)calloc((size_t)rank, sizeof(hsize_t));
    if (rank > 0 && (dims == NULL || start == NULL || selectionStride == NULL || count == NULL)) {
        preview.errorMessage = hd_copy_string("Out of memory while preparing dataset preview");
        free(dims);
        free(start);
        free(selectionStride);
        free(count);
        H5Sclose(fileSpaceID);
        H5Tclose(fileTypeID);
        H5Dclose(datasetID);
        return preview;
    }

    hsize_t totalElements = hd_dataspace_element_count(fileSpaceID);
    H5T_class_t datasetTypeClass = H5Tget_class(fileTypeID);
    bool isCompoundDataset = datasetTypeClass == H5T_COMPOUND;
    uint64_t totalRows = rank == 0 ? 1 : 0;
    uint64_t totalColumns = 1;
    if (rank > 0) {
        H5Sget_simple_extent_dims(fileSpaceID, dims, NULL);
        totalRows = (uint64_t)dims[0];
        if (isCompoundDataset)
            totalColumns = (uint64_t)H5Tget_nmembers(fileTypeID);
        else if (rank > 1)
            totalColumns = (uint64_t)dims[1];
    } else if (isCompoundDataset) {
        totalColumns = (uint64_t)H5Tget_nmembers(fileTypeID);
    }

    preview.startRow = startRow;
    preview.rowStride = 1;
    preview.totalRowCount = totalRows;
    preview.totalColumnCount = totalColumns;

    uint64_t availableRowsFromStart = startRow < totalRows ? totalRows - startRow : 0;
    uint64_t sampleAvailableRows = availableRowsFromStart;
    if (sampleFullRange && sampleRowCount > 0 && sampleRowCount < sampleAvailableRows)
        sampleAvailableRows = sampleRowCount;

    uint64_t rowStride = 1;
    if (sampleFullRange && sampleAvailableRows > maxRows && maxRows > 0) {
        rowStride = (sampleAvailableRows + maxRows - 1) / maxRows;
        if (rowStride == 0)
            rowStride = 1;
    }
    preview.rowStride = rowStride;

    if (totalElements == 0 || startRow >= totalRows) {
        preview.text = hd_copy_string("");
        preview.columnLabels = hd_copy_string("");
        preview.columnDisplayPrecisions = hd_copy_string("");
        preview.xAxisLabel = hd_copy_string("");
        preview.xAxisValues = hd_copy_string("");
        preview.xAxisSource = hd_copy_string("");
        preview.xAxisDisplayPrecision = 0;
        preview.summary = totalElements == 0
            ? hd_copy_string("Empty dataset")
            : hd_format_string("No rows at offset %llu", (unsigned long long)startRow);
        preview.rowCount = 0;
        preview.columnCount = totalColumns < maxColumns ? totalColumns : maxColumns;
        preview.isTruncated = startRow < totalRows;
        free(dims);
        free(start);
        free(selectionStride);
        free(count);
        H5Sclose(fileSpaceID);
        H5Tclose(fileTypeID);
        H5Dclose(datasetID);
        return preview;
    }

    uint64_t rows = 1;
    uint64_t columns = 1;
    uint64_t valueCount = 1;

    if (rank > 0) {
        for (int index = 0; index < rank; index++) {
            selectionStride[index] = 1;
            count[index] = 1;
        }
        selectionStride[0] = (hsize_t)rowStride;

        if (isCompoundDataset) {
            uint64_t availableRows = sampleFullRange ? sampleAvailableRows : availableRowsFromStart;
            uint64_t stridedRows = ((availableRows - 1) / rowStride) + 1;
            rows = stridedRows < maxRows ? stridedRows : maxRows;
            columns = hd_compound_supported_column_count(
                fileTypeID,
                totalColumns < maxColumns ? totalColumns : maxColumns
            );
            if (columns == 0)
                columns = totalColumns < maxColumns ? totalColumns : maxColumns;
            if (hd_mul_would_overflow(rows, columns) || rows * columns > maxScalarValues) {
                rows = columns == 0 ? 0 : maxScalarValues / columns;
                if (rows == 0)
                    rows = 1;
            }
            start[0] = (hsize_t)startRow;
            count[0] = rows;
        } else if (rank == 1) {
            uint64_t availableRows = sampleFullRange ? sampleAvailableRows : availableRowsFromStart;
            uint64_t limit = maxRows < maxScalarValues ? maxRows : maxScalarValues;
            uint64_t stridedRows = ((availableRows - 1) / rowStride) + 1;
            rows = stridedRows < limit ? stridedRows : limit;
            columns = 1;
            start[0] = (hsize_t)startRow;
            count[0] = rows;
        } else {
            uint64_t availableRows = sampleFullRange ? sampleAvailableRows : availableRowsFromStart;
            uint64_t stridedRows = ((availableRows - 1) / rowStride) + 1;
            rows = stridedRows < maxRows ? stridedRows : maxRows;
            columns = totalColumns < maxColumns ? totalColumns : maxColumns;
            if (hd_mul_would_overflow(rows, columns) || rows * columns > maxScalarValues) {
                columns = rows == 0 ? 0 : maxScalarValues / rows;
                if (columns == 0)
                    columns = 1;
            }
            start[0] = (hsize_t)startRow;
            count[0] = rows;
            count[1] = columns;

            // Pin every dimension past the first two to a caller-chosen slice
            // index (defaulting to 0), so 3D+ datasets show one 2D plane at a time.
            for (int index = 2; index < rank; index++) {
                uint64_t sliceIndex = (size_t)(index - 2) < sliceCount
                    ? sliceStarts[index - 2]
                    : 0;
                if (dims[index] > 0 && sliceIndex >= (uint64_t)dims[index])
                    sliceIndex = (uint64_t)dims[index] - 1;
                start[index] = (hsize_t)sliceIndex;
            }
        }

        valueCount = rows * columns;
        H5Sselect_hyperslab(fileSpaceID, H5S_SELECT_SET, start, selectionStride, count, NULL);
    }

    hid_t memorySpaceID = rank == 0 ? H5Screate(H5S_SCALAR) : H5Screate_simple(rank, count, NULL);
    if (memorySpaceID < 0) {
        preview.errorMessage = hd_copy_string("Could not allocate HDF5 memory dataspace");
        free(dims);
        free(start);
        free(selectionStride);
        free(count);
        H5Sclose(fileSpaceID);
        H5Tclose(fileTypeID);
        H5Dclose(datasetID);
        return preview;
    }

    HDStringBuilder builder = {0};
    char *columnLabels = NULL;
    char *columnDisplayPrecisions = NULL;
    char *xAxisLabel = NULL;
    char *xAxisValues = NULL;
    char *xAxisSource = NULL;
    int xAxisDisplayPrecision = 0;
    bool didRead = hd_read_values_into_builder(datasetID,
                                               fileTypeID,
                                               fileSpaceID,
                                               memorySpaceID,
                                               false,
                                               rows,
                                               columns,
                                               valueCount,
                                               &builder,
                                               &columnLabels,
                                               &columnDisplayPrecisions);
    if (didRead) {
        hd_copy_preview_x_axis(file,
                               datasetID,
                               datasetPath,
                               startRow,
                               rows,
                               rowStride,
                               &xAxisValues,
                               &xAxisLabel,
                               &xAxisSource,
                               &xAxisDisplayPrecision);
        preview.text = hd_sb_finish(&builder);
        preview.columnLabels = columnLabels == NULL ? hd_copy_string("") : columnLabels;
        preview.columnDisplayPrecisions = columnDisplayPrecisions == NULL ? hd_copy_string("") : columnDisplayPrecisions;
        preview.xAxisLabel = xAxisLabel == NULL ? hd_copy_string("") : xAxisLabel;
        preview.xAxisValues = xAxisValues == NULL ? hd_copy_string("") : xAxisValues;
        preview.xAxisSource = xAxisSource == NULL ? hd_copy_string("") : xAxisSource;
        preview.xAxisDisplayPrecision = xAxisDisplayPrecision;
        preview.startRow = startRow;
        preview.rowStride = rowStride;
        preview.rowCount = rows;
        preview.columnCount = columns;
        preview.totalRowCount = totalRows;
        preview.totalColumnCount = totalColumns;
        preview.isTruncated = startRow + rows < totalRows || columns < totalColumns || totalElements > (hsize_t)valueCount;
        if (sampleFullRange && rowStride > 1) {
            preview.summary = hd_format_string("Sampled %llu rows across %llu rows (stride %llu)",
                                               (unsigned long long)rows,
                                               (unsigned long long)sampleAvailableRows,
                                               (unsigned long long)rowStride);
        } else if (rank <= 1 && !isCompoundDataset) {
            preview.summary = hd_format_string("Showing values %llu-%llu of %llu",
                                               (unsigned long long)(startRow + 1),
                                               (unsigned long long)(startRow + ((rows - 1) * rowStride) + 1),
                                               (unsigned long long)totalRows);
        } else {
            preview.summary = hd_format_string("Showing rows %llu-%llu, columns 1-%llu of %llu x %llu",
                                               (unsigned long long)(startRow + 1),
                                               (unsigned long long)(startRow + ((rows - 1) * rowStride) + 1),
                                               (unsigned long long)columns,
                                               (unsigned long long)totalRows,
                                               (unsigned long long)totalColumns);
        }
    } else {
        hd_sb_dispose(&builder);
        free(columnLabels);
        free(columnDisplayPrecisions);
        free(xAxisLabel);
        free(xAxisValues);
        free(xAxisSource);
        char *typeDescription = hd_copy_datatype_description(fileTypeID);
        preview.text = hd_copy_string("");
        preview.columnLabels = hd_copy_string("");
        preview.columnDisplayPrecisions = hd_copy_string("");
        preview.xAxisLabel = hd_copy_string("");
        preview.xAxisValues = hd_copy_string("");
        preview.xAxisSource = hd_copy_string("");
        preview.xAxisDisplayPrecision = 0;
        preview.summary = hd_format_string("Preview unavailable for %s datasets", typeDescription == NULL ? "this" : typeDescription);
        free(typeDescription);
        preview.startRow = startRow;
        preview.rowStride = rowStride;
        preview.rowCount = 0;
        preview.columnCount = 0;
        preview.totalRowCount = totalRows;
        preview.totalColumnCount = totalColumns;
        preview.isTruncated = true;
    }

    free(dims);
    free(start);
    free(selectionStride);
    free(count);
    H5Sclose(memorySpaceID);
    H5Sclose(fileSpaceID);
    H5Tclose(fileTypeID);
    H5Dclose(datasetID);
    return preview;
}

HDHDFDatasetPreview HDHDFCopyDatasetPreviewWindow(HDHDFFile *file,
                                                  const char *datasetPath,
                                                  uint64_t startRow,
                                                  uint64_t maxRows,
                                                  uint64_t maxColumns,
                                                  uint64_t maxScalarValues)
{
    return hd_copy_dataset_preview_window(file, datasetPath, startRow, maxRows, maxColumns, maxScalarValues, false, 0, NULL, 0);
}

HDHDFDatasetPreview HDHDFCopyDatasetPreviewWindowSliced(HDHDFFile *file,
                                                        const char *datasetPath,
                                                        uint64_t startRow,
                                                        uint64_t maxRows,
                                                        uint64_t maxColumns,
                                                        uint64_t maxScalarValues,
                                                        const uint64_t *sliceStarts,
                                                        size_t sliceCount)
{
    return hd_copy_dataset_preview_window(file, datasetPath, startRow, maxRows, maxColumns, maxScalarValues, false, 0, sliceStarts, sliceCount);
}

HDHDFDatasetPreview HDHDFCopyDatasetPlotPreview(HDHDFFile *file,
                                                const char *datasetPath,
                                                uint64_t targetRows,
                                                uint64_t maxColumns,
                                                uint64_t maxScalarValues)
{
    if (targetRows == 0)
        targetRows = 1024;
    return hd_copy_dataset_preview_window(file, datasetPath, 0, targetRows, maxColumns, maxScalarValues, true, 0, NULL, 0);
}

HDHDFDatasetPreview HDHDFCopyDatasetPlotPreviewWindow(HDHDFFile *file,
                                                      const char *datasetPath,
                                                      uint64_t startRow,
                                                      uint64_t rowCount,
                                                      uint64_t targetRows,
                                                      uint64_t maxColumns,
                                                      uint64_t maxScalarValues)
{
    if (targetRows == 0)
        targetRows = 1024;
    if (rowCount == 0)
        rowCount = targetRows;
    return hd_copy_dataset_preview_window(
        file,
        datasetPath,
        startRow,
        targetRows,
        maxColumns,
        maxScalarValues,
        true,
        rowCount,
        NULL,
        0
    );
}

HDHDFDatasetPreview HDHDFCopyDatasetPreview(HDHDFFile *file,
                                            const char *datasetPath,
                                            uint64_t maxRows,
                                            uint64_t maxColumns,
                                            uint64_t maxScalarValues)
{
    return HDHDFCopyDatasetPreviewWindow(file, datasetPath, 0, maxRows, maxColumns, maxScalarValues);
}

static uint8_t hd_clamp_to_byte(double value)
{
    if (value != value)  // NaN
        return 0;
    if (value <= 0.0)
        return 0;
    if (value >= 255.0)
        return 255;
    return (uint8_t)(value + 0.5);
}

HDHDFDatasetImage HDHDFCopyDatasetImage(HDHDFFile *file,
                                        const char *datasetPath,
                                        uint32_t maxDimension)
{
    HDHDFDatasetImage image;
    memset(&image, 0, sizeof(image));

    if (file == NULL) {
        image.errorMessage = hd_copy_string("No HDF5 file is open");
        return image;
    }
    if (datasetPath == NULL || datasetPath[0] == '\0') {
        image.errorMessage = hd_copy_string("No dataset path was provided");
        return image;
    }
    if (maxDimension == 0)
        maxDimension = 2048;

    hid_t datasetID = H5Dopen2(file->fileID, datasetPath, H5P_DEFAULT);
    if (datasetID < 0) {
        image.errorMessage = hd_format_string("Could not open dataset %s", datasetPath);
        return image;
    }

    hid_t fileTypeID = H5Dget_type(datasetID);
    hid_t fileSpaceID = H5Dget_space(datasetID);
    float *samples = NULL;
    if (fileTypeID < 0 || fileSpaceID < 0) {
        image.errorMessage = hd_format_string("Could not inspect dataset %s", datasetPath);
        goto cleanup;
    }

    H5T_class_t typeClass = H5Tget_class(fileTypeID);
    if (typeClass != H5T_INTEGER && typeClass != H5T_FLOAT) {
        image.errorMessage = hd_copy_string("This dataset isn't numeric, so it can't be shown as an image.");
        goto cleanup;
    }

    int rank = H5Sget_simple_extent_ndims(fileSpaceID);
    if (rank != 2 && rank != 3) {
        image.errorMessage = hd_format_string(
            "Only 2D and 3D datasets can be shown as an image (this one is %dD).", rank);
        goto cleanup;
    }

    hsize_t dims[3] = {0, 0, 0};
    if (H5Sget_simple_extent_dims(fileSpaceID, dims, NULL) < 0) {
        image.errorMessage = hd_copy_string("Could not read dataset dimensions");
        goto cleanup;
    }

    uint64_t sourceHeight = (uint64_t)dims[0];
    uint64_t sourceWidth = (uint64_t)dims[1];
    uint64_t channels = rank == 3 ? (uint64_t)dims[2] : 1;
    if (sourceHeight == 0 || sourceWidth == 0) {
        image.errorMessage = hd_copy_string("This dataset is empty.");
        goto cleanup;
    }
    if (rank == 3 && (channels < 1 || channels > 4)) {
        image.errorMessage = hd_format_string(
            "A 3D dataset needs 1-4 channels in its last dimension to be shown as an image "
            "(this one has %llu).",
            (unsigned long long)channels);
        goto cleanup;
    }

    uint64_t maxSide = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
    uint64_t stride = 1;
    if (maxSide > (uint64_t)maxDimension)
        stride = (maxSide + maxDimension - 1) / maxDimension;
    uint64_t outHeight = (sourceHeight - 1) / stride + 1;
    uint64_t outWidth = (sourceWidth - 1) / stride + 1;

    hsize_t start[3] = {0, 0, 0};
    hsize_t strideArr[3] = {stride, stride, 1};
    hsize_t count[3] = {outHeight, outWidth, channels};
    if (H5Sselect_hyperslab(fileSpaceID, H5S_SELECT_SET, start, strideArr, count, NULL) < 0) {
        image.errorMessage = hd_copy_string("Could not select image pixels");
        goto cleanup;
    }

    hid_t memSpaceID = H5Screate_simple(rank, count, NULL);
    if (memSpaceID < 0) {
        image.errorMessage = hd_copy_string("Out of memory while preparing the image");
        goto cleanup;
    }

    uint64_t sampleCount = outHeight * outWidth * channels;
    samples = (float *)calloc((size_t)sampleCount, sizeof(float));
    if (samples == NULL) {
        H5Sclose(memSpaceID);
        image.errorMessage = hd_copy_string("Out of memory while reading the image");
        goto cleanup;
    }

    herr_t readStatus = H5Dread(datasetID, H5T_NATIVE_FLOAT, memSpaceID, fileSpaceID,
                                H5P_DEFAULT, samples);
    H5Sclose(memSpaceID);
    if (readStatus < 0) {
        image.errorMessage = hd_copy_string("Could not read image data");
        goto cleanup;
    }

    // 8-bit unsigned data is already display-ready and passes through untouched;
    // everything else is min/max scaled into 0..255 over its colour channels.
    bool isUint8 = typeClass == H5T_INTEGER &&
                   H5Tget_size(fileTypeID) == 1 &&
                   H5Tget_sign(fileTypeID) == H5T_SGN_NONE;
    bool hasAlpha = channels == 2 || channels == 4;
    uint64_t alphaChannel = channels - 1;

    double minValue = 0.0;
    double maxValue = 255.0;
    if (!isUint8) {
        bool haveExtent = false;
        for (uint64_t index = 0; index < sampleCount; index++) {
            if (hasAlpha && index % channels == alphaChannel)
                continue;  // don't let alpha skew the colour range
            float value = samples[index];
            if (value != value)  // NaN
                continue;
            if (!haveExtent) {
                minValue = maxValue = value;
                haveExtent = true;
            } else if (value < minValue) {
                minValue = value;
            } else if (value > maxValue) {
                maxValue = value;
            }
        }
        if (!haveExtent) {
            minValue = 0.0;
            maxValue = 1.0;
        }
    }
    double range = maxValue - minValue;
    double scale = range > 0.0 ? 255.0 / range : 0.0;

    uint8_t *rgba = (uint8_t *)calloc((size_t)(outWidth * outHeight * 4), 1);
    if (rgba == NULL) {
        image.errorMessage = hd_copy_string("Out of memory while building the image");
        goto cleanup;
    }

    for (uint64_t pixel = 0; pixel < outWidth * outHeight; pixel++) {
        const float *source = &samples[pixel * channels];
        uint8_t component[3];
        for (int c = 0; c < 3; c++) {
            // grayscale (1/2 channels) replicates channel 0 across R/G/B.
            uint64_t sourceChannel = channels >= 3 ? (uint64_t)c : 0;
            double value = (double)source[sourceChannel];
            component[c] = isUint8 ? hd_clamp_to_byte(value)
                                   : hd_clamp_to_byte((value - minValue) * scale);
        }
        uint8_t alpha = 255;
        if (hasAlpha && isUint8)
            alpha = hd_clamp_to_byte((double)source[alphaChannel]);

        // Premultiply so the buffer matches kCGImageAlphaPremultipliedLast.
        uint8_t *out = &rgba[pixel * 4];
        out[0] = (uint8_t)((component[0] * alpha + 127) / 255);
        out[1] = (uint8_t)((component[1] * alpha + 127) / 255);
        out[2] = (uint8_t)((component[2] * alpha + 127) / 255);
        out[3] = alpha;
    }

    image.rgba = rgba;
    image.width = (uint32_t)outWidth;
    image.height = (uint32_t)outHeight;
    image.channels = (uint32_t)channels;
    image.sourceWidth = sourceWidth;
    image.sourceHeight = sourceHeight;
    image.isDownsampled = stride > 1;
    image.isNormalized = !isUint8;
    image.minValue = minValue;
    image.maxValue = maxValue;

cleanup:
    free(samples);
    if (fileSpaceID >= 0)
        H5Sclose(fileSpaceID);
    if (fileTypeID >= 0)
        H5Tclose(fileTypeID);
    H5Dclose(datasetID);
    return image;
}

void HDHDFFreeString(char *string)
{
    free(string);
}

void HDHDFFreeObjectInfo(HDHDFObjectInfo *info)
{
    if (info == NULL)
        return;

    free(info->name);
    free(info->path);
    free(info->typeDescription);
    free(info->shapeDescription);
    free(info->linkTarget);
    memset(info, 0, sizeof(*info));
}

void HDHDFFreeObjectList(HDHDFObjectList *list)
{
    if (list == NULL)
        return;

    for (size_t index = 0; index < list->count; index++)
        HDHDFFreeObjectInfo(&list->items[index]);
    free(list->items);
    free(list->errorMessage);
    memset(list, 0, sizeof(*list));
}

void HDHDFFreeAttributeList(HDHDFAttributeList *list)
{
    if (list == NULL)
        return;

    for (size_t index = 0; index < list->count; index++) {
        free(list->items[index].name);
        free(list->items[index].typeDescription);
        free(list->items[index].shapeDescription);
        free(list->items[index].valuePreview);
    }
    free(list->items);
    free(list->errorMessage);
    memset(list, 0, sizeof(*list));
}

void HDHDFFreeDatasetPreview(HDHDFDatasetPreview *preview)
{
    if (preview == NULL)
        return;

    free(preview->text);
    free(preview->summary);
    free(preview->columnLabels);
    free(preview->columnDisplayPrecisions);
    free(preview->xAxisLabel);
    free(preview->xAxisValues);
    free(preview->xAxisSource);
    free(preview->errorMessage);
    memset(preview, 0, sizeof(*preview));
}

void HDHDFFreeDatasetImage(HDHDFDatasetImage *image)
{
    if (image == NULL)
        return;

    free(image->rgba);
    free(image->errorMessage);
    memset(image, 0, sizeof(*image));
}
