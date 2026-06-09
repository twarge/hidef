// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

#ifndef HIDEF_HDF5_H
#define HIDEF_HDF5_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HDHDFFile HDHDFFile;

typedef enum {
    HDHDFObjectKindUnknown = 0,
    HDHDFObjectKindGroup = 1,
    HDHDFObjectKindDataset = 2,
    HDHDFObjectKindNamedDatatype = 3,
    HDHDFObjectKindLink = 4
} HDHDFObjectKind;

typedef enum {
    HDHDFLinkKindHard = 0,
    HDHDFLinkKindSoft = 1,
    HDHDFLinkKindExternal = 2,
    HDHDFLinkKindUserDefined = 3,
    HDHDFLinkKindUnknown = 4
} HDHDFLinkKind;

typedef struct {
    char *name;
    char *path;
    HDHDFObjectKind kind;
    HDHDFLinkKind linkKind;
    uint64_t childCount;
    uint64_t attributeCount;
    uint64_t storageSize;
    char *typeDescription;
    char *shapeDescription;
    char *linkTarget;
} HDHDFObjectInfo;

typedef struct {
    HDHDFObjectInfo *items;
    size_t count;
    char *errorMessage;
} HDHDFObjectList;

typedef struct {
    char *name;
    char *typeDescription;
    char *shapeDescription;
    char *valuePreview;
    bool isValueTruncated;
} HDHDFAttributeInfo;

typedef struct {
    HDHDFAttributeInfo *items;
    size_t count;
    char *errorMessage;
} HDHDFAttributeList;

typedef struct {
    char *text;
    char *summary;
    char *columnLabels;
    char *columnDisplayPrecisions;
    char *xAxisLabel;
    char *xAxisValues;
    char *xAxisSource;
    int xAxisDisplayPrecision;
    uint64_t startRow;
    uint64_t rowStride;
    uint64_t rowCount;
    uint64_t columnCount;
    uint64_t totalRowCount;
    uint64_t totalColumnCount;
    bool isTruncated;
    char *errorMessage;
} HDHDFDatasetPreview;

typedef struct {
    uint8_t *rgba;          // premultiplied RGBA8, width*height*4 bytes, row-major, top-left origin
    uint32_t width;         // rendered width (after any downsampling)
    uint32_t height;        // rendered height
    uint32_t channels;      // source channel count (1 for 2D datasets, otherwise the last dim, 1..4)
    uint64_t sourceWidth;   // original width  (dims[1])
    uint64_t sourceHeight;  // original height (dims[0])
    bool isDownsampled;     // true if the image was strided down to fit maxDimension
    bool isNormalized;      // true if non-8-bit values were min/max scaled into 0..255
    double minValue;        // sampled minimum used for normalization
    double maxValue;        // sampled maximum used for normalization
    char *errorMessage;
} HDHDFDatasetImage;

HDHDFFile *HDHDFOpenFile(const char *path, char **errorMessage);
void HDHDFCloseFile(HDHDFFile *file);

HDHDFObjectInfo HDHDFCopyRootObjectInfo(HDHDFFile *file, char **errorMessage);
HDHDFObjectInfo HDHDFCopyObjectInfo(HDHDFFile *file, const char *path, char **errorMessage);
HDHDFObjectList HDHDFCopyChildren(HDHDFFile *file, const char *groupPath);
HDHDFAttributeList HDHDFCopyAttributes(HDHDFFile *file, const char *objectPath, size_t valueByteLimit);
HDHDFDatasetPreview HDHDFCopyDatasetPreview(HDHDFFile *file,
                                            const char *datasetPath,
                                            uint64_t maxRows,
                                            uint64_t maxColumns,
                                            uint64_t maxScalarValues);
HDHDFDatasetPreview HDHDFCopyDatasetPreviewWindow(HDHDFFile *file,
                                                  const char *datasetPath,
                                                  uint64_t startRow,
                                                  uint64_t maxRows,
                                                  uint64_t maxColumns,
                                                  uint64_t maxScalarValues);
HDHDFDatasetPreview HDHDFCopyDatasetPreviewWindowSliced(HDHDFFile *file,
                                                        const char *datasetPath,
                                                        uint64_t startRow,
                                                        uint64_t maxRows,
                                                        uint64_t maxColumns,
                                                        uint64_t maxScalarValues,
                                                        const uint64_t *sliceStarts,
                                                        size_t sliceCount);
HDHDFDatasetPreview HDHDFCopyDatasetPlotPreview(HDHDFFile *file,
                                                const char *datasetPath,
                                                uint64_t targetRows,
                                                uint64_t maxColumns,
                                                uint64_t maxScalarValues);
HDHDFDatasetPreview HDHDFCopyDatasetPlotPreviewWindow(HDHDFFile *file,
                                                      const char *datasetPath,
                                                      uint64_t startRow,
                                                      uint64_t rowCount,
                                                      uint64_t targetRows,
                                                      uint64_t maxColumns,
                                                      uint64_t maxScalarValues);
HDHDFDatasetImage HDHDFCopyDatasetImage(HDHDFFile *file,
                                        const char *datasetPath,
                                        uint32_t maxDimension);

void HDHDFFreeString(char *string);
void HDHDFFreeObjectInfo(HDHDFObjectInfo *info);
void HDHDFFreeObjectList(HDHDFObjectList *list);
void HDHDFFreeAttributeList(HDHDFAttributeList *list);
void HDHDFFreeDatasetPreview(HDHDFDatasetPreview *preview);
void HDHDFFreeDatasetImage(HDHDFDatasetImage *image);

#ifdef __cplusplus
}
#endif

#endif
