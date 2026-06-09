// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

#include "HiDeFHDF5.h"

#include <hdf5.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t sample_number;
    double time;
    double sine;
    double cosine;
} SmokeSample;

static int write_fixed_string_attribute(hid_t object, const char *name, const char *value)
{
    hsize_t dims[1] = {1};
    hid_t space = H5Screate_simple(1, dims, NULL);
    hid_t type = H5Tcopy(H5T_C_S1);
    H5Tset_size(type, strlen(value) + 1);
    hid_t attr = H5Acreate2(object, name, type, space, H5P_DEFAULT, H5P_DEFAULT);
    int ok = H5Awrite(attr, type, value) >= 0;
    H5Aclose(attr);
    H5Tclose(type);
    H5Sclose(space);
    return ok;
}

static int write_variable_string_vector_attribute(hid_t object,
                                                  const char *name,
                                                  const char *const *values,
                                                  hsize_t count)
{
    hid_t space = H5Screate_simple(1, &count, NULL);
    hid_t type = H5Tcopy(H5T_C_S1);
    if (space < 0 || type < 0) {
        if (type >= 0)
            H5Tclose(type);
        if (space >= 0)
            H5Sclose(space);
        return 0;
    }

    H5Tset_size(type, H5T_VARIABLE);
    H5Tset_cset(type, H5T_CSET_UTF8);
    hid_t attr = H5Acreate2(object, name, type, space, H5P_DEFAULT, H5P_DEFAULT);
    int ok = attr >= 0 && H5Awrite(attr, type, values) >= 0;
    if (attr >= 0)
        H5Aclose(attr);
    H5Tclose(type);
    H5Sclose(space);
    return ok;
}

static int fail(const char *message)
{
    fprintf(stderr, "Smoke test failed: %s\n", message);
    return 1;
}

static int create_fixture(const char *path)
{
    hid_t file = H5Fcreate(path, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
    if (file < 0)
        return 0;

    hid_t group = H5Gcreate2(file, "/group", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (group < 0)
        return 0;

    hid_t scalarSpace = H5Screate(H5S_SCALAR);
    hid_t samplingRateAttr = H5Acreate2(group, "sampling_rate", H5T_IEEE_F64LE, scalarSpace, H5P_DEFAULT, H5P_DEFAULT);
    double samplingRate = 2.0;
    if (H5Awrite(samplingRateAttr, H5T_NATIVE_DOUBLE, &samplingRate) < 0)
        return 0;
    H5Aclose(samplingRateAttr);
    hid_t startTimeAttr = H5Acreate2(group, "start_time", H5T_IEEE_F64LE, scalarSpace, H5P_DEFAULT, H5P_DEFAULT);
    double startTime = 10.0;
    if (H5Awrite(startTimeAttr, H5T_NATIVE_DOUBLE, &startTime) < 0)
        return 0;
    H5Aclose(startTimeAttr);
    H5Sclose(scalarSpace);

    hsize_t dims[2] = {4, 3};
    hid_t space = H5Screate_simple(2, dims, NULL);
    hid_t dataset = H5Dcreate2(group, "matrix", H5T_STD_I32LE, space, H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    int values[12];
    for (int index = 0; index < 12; index++)
        values[index] = index;

    if (H5Dwrite(dataset, H5T_NATIVE_INT, H5S_ALL, H5S_ALL, H5P_DEFAULT, values) < 0)
        return 0;

    hsize_t sampleDims[1] = {3};
    hid_t sampleSpace = H5Screate_simple(1, sampleDims, NULL);
    hid_t sampleType = H5Tcreate(H5T_COMPOUND, sizeof(SmokeSample));
    H5Tinsert(sampleType, "sample_number", HOFFSET(SmokeSample, sample_number), H5T_NATIVE_UINT32);
    H5Tinsert(sampleType, "time", HOFFSET(SmokeSample, time), H5T_NATIVE_DOUBLE);
    H5Tinsert(sampleType, "sine", HOFFSET(SmokeSample, sine), H5T_NATIVE_DOUBLE);
    H5Tinsert(sampleType, "cosine", HOFFSET(SmokeSample, cosine), H5T_NATIVE_DOUBLE);
    hid_t sampleDataset = H5Dcreate2(group, "samples", sampleType, sampleSpace, H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    SmokeSample samples[3] = {
        {0, 1.5, 0.25, 1.0},
        {1, 2.5, 0.5, 0.75},
        {2, 3.5, 0.75, 0.5}
    };
    if (H5Dwrite(sampleDataset, sampleType, H5S_ALL, H5S_ALL, H5P_DEFAULT, samples) < 0)
        return 0;

    H5Dclose(sampleDataset);
    H5Tclose(sampleType);
    H5Sclose(sampleSpace);

    hsize_t attrDims[1] = {1};
    hid_t attrSpace = H5Screate_simple(1, attrDims, NULL);
    hid_t attrType = H5Tcopy(H5T_C_S1);
    H5Tset_size(attrType, 8);
    hid_t attr = H5Acreate2(dataset, "units", attrType, attrSpace, H5P_DEFAULT, H5P_DEFAULT);
    const char units[8] = "counts";
    if (H5Awrite(attr, attrType, units) < 0)
        return 0;

    H5Aclose(attr);
    H5Tclose(attrType);
    H5Sclose(attrSpace);

    const char *fieldDescriptions[3] = {
        "Row index",
        "Column index",
        "Integer count"
    };
    if (!write_variable_string_vector_attribute(dataset, "field_descriptions", fieldDescriptions, 3))
        return 0;

    H5Dclose(dataset);
    H5Sclose(space);
    H5Gclose(group);

    hid_t scaleGroup = H5Gcreate2(file, "/scale_group", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (scaleGroup < 0)
        return 0;

    hsize_t scaledDims[1] = {3};
    hid_t scaledSpace = H5Screate_simple(1, scaledDims, NULL);
    hid_t scaledDataset = H5Dcreate2(scaleGroup, "values", H5T_IEEE_F64LE, scaledSpace, H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    double scaledValues[3] = {5.0, 6.0, 7.0};
    if (H5Dwrite(scaledDataset, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, scaledValues) < 0)
        return 0;

    hid_t scaleDataset = H5Dcreate2(scaleGroup, "axis", H5T_IEEE_F64LE, scaledSpace, H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    double axisValues[3] = {100.0, 101.0, 102.0};
    if (H5Dwrite(scaleDataset, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, axisValues) < 0)
        return 0;
    if (!write_fixed_string_attribute(scaleDataset, "CLASS", "DIMENSION_SCALE"))
        return 0;
    if (!write_fixed_string_attribute(scaleDataset, "NAME", "time"))
        return 0;

    hid_t refType = H5Tvlen_create(H5T_STD_REF_OBJ);
    hsize_t dimensionListDims[1] = {1};
    hid_t dimensionListSpace = H5Screate_simple(1, dimensionListDims, NULL);
    hid_t dimensionListAttr = H5Acreate2(scaledDataset, "DIMENSION_LIST", refType, dimensionListSpace, H5P_DEFAULT, H5P_DEFAULT);
    hobj_ref_t axisReference;
    if (H5Rcreate(&axisReference, file, "/scale_group/axis", H5R_OBJECT, -1) < 0)
        return 0;
    hvl_t dimensionList[1] = {{.len = 1, .p = &axisReference}};
    if (H5Awrite(dimensionListAttr, refType, dimensionList) < 0)
        return 0;

    H5Aclose(dimensionListAttr);
    H5Sclose(dimensionListSpace);
    H5Tclose(refType);
    H5Dclose(scaleDataset);
    H5Dclose(scaledDataset);
    H5Sclose(scaledSpace);
    H5Gclose(scaleGroup);

    hid_t precisionGroup = H5Gcreate2(file, "/precision_group", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (precisionGroup < 0)
        return 0;

    hid_t precisionScalarSpace = H5Screate(H5S_SCALAR);
    hid_t precisionSamplingRateAttr = H5Acreate2(precisionGroup, "sampling_rate", H5T_IEEE_F64LE, precisionScalarSpace, H5P_DEFAULT, H5P_DEFAULT);
    double precisionSamplingRate = 10.0;
    if (H5Awrite(precisionSamplingRateAttr, H5T_NATIVE_DOUBLE, &precisionSamplingRate) < 0)
        return 0;
    H5Aclose(precisionSamplingRateAttr);
    hid_t precisionStartTimeAttr = H5Acreate2(precisionGroup, "start_time", H5T_IEEE_F64LE, precisionScalarSpace, H5P_DEFAULT, H5P_DEFAULT);
    double precisionStartTime = 1717080000.123456;
    if (H5Awrite(precisionStartTimeAttr, H5T_NATIVE_DOUBLE, &precisionStartTime) < 0)
        return 0;
    H5Aclose(precisionStartTimeAttr);
    H5Sclose(precisionScalarSpace);

    hsize_t precisionDims[1] = {2};
    hid_t precisionSpace = H5Screate_simple(1, precisionDims, NULL);
    hid_t precisionDataset = H5Dcreate2(precisionGroup, "values", H5T_IEEE_F64LE, precisionSpace, H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    double precisionValues[2] = {0.12345678901234567, 1.2345678901234567};
    if (H5Dwrite(precisionDataset, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, precisionValues) < 0)
        return 0;

    H5Dclose(precisionDataset);
    H5Sclose(precisionSpace);
    H5Gclose(precisionGroup);

    H5Fclose(file);
    return 1;
}

int main(void)
{
    const char *path = "/private/tmp/hidef-smoke.h5";
    remove(path);

    if (!create_fixture(path))
        return fail("could not create fixture");

    char *error = NULL;
    HDHDFFile *file = HDHDFOpenFile(path, &error);
    if (file == NULL) {
        fprintf(stderr, "%s\n", error == NULL ? "unknown open error" : error);
        HDHDFFreeString(error);
        return fail("could not open fixture through shim");
    }

    HDHDFObjectList rootChildren = HDHDFCopyChildren(file, "/");
    if (rootChildren.errorMessage != NULL)
        return fail(rootChildren.errorMessage);
    if (rootChildren.count != 3)
        return fail("root should contain three children");
    if (strcmp(rootChildren.items[0].path, "/group") != 0)
        return fail("root child path mismatch");
    HDHDFFreeObjectList(&rootChildren);

    HDHDFObjectList groupChildren = HDHDFCopyChildren(file, "/group");
    if (groupChildren.errorMessage != NULL)
        return fail(groupChildren.errorMessage);
    if (groupChildren.count != 2)
        return fail("group should contain two datasets");
    if (groupChildren.items[0].kind != HDHDFObjectKindDataset)
        return fail("group child should be a dataset");
    if (strcmp(groupChildren.items[0].shapeDescription, "4 x 3") != 0)
        return fail("dataset shape mismatch");
    HDHDFFreeObjectList(&groupChildren);

    HDHDFAttributeList attributes = HDHDFCopyAttributes(file, "/group/matrix", 1024);
    if (attributes.errorMessage != NULL)
        return fail(attributes.errorMessage);
    if (attributes.count != 2)
        return fail("dataset should have two attributes");
    if (strcmp(attributes.items[0].name, "field_descriptions") != 0)
        return fail("variable string attribute name mismatch");
    if (strcmp(attributes.items[0].typeDescription, "variable-length string") != 0)
        return fail("variable string attribute type mismatch");
    if (strcmp(attributes.items[0].valuePreview, "Row index\tColumn index\tInteger count") != 0) {
        fprintf(stderr, "Actual variable string preview: <%s>\n", attributes.items[0].valuePreview);
        return fail("variable string attribute preview mismatch");
    }
    if (strcmp(attributes.items[1].name, "units") != 0)
        return fail("attribute name mismatch");
    if (strcmp(attributes.items[1].valuePreview, "counts") != 0)
        return fail("attribute preview mismatch");
    HDHDFFreeAttributeList(&attributes);

    HDHDFDatasetPreview preview = HDHDFCopyDatasetPreview(file, "/group/matrix", 2, 2, 4);
    if (preview.errorMessage != NULL)
        return fail(preview.errorMessage);
    if (strcmp(preview.text, "0\t1\n3\t4") != 0)
        return fail("dataset preview mismatch");
    if (preview.startRow != 0 || preview.rowCount != 2 || preview.columnCount != 2)
        return fail("dataset preview dimensions mismatch");
    if (preview.rowStride != 1)
        return fail("dataset preview row stride mismatch");
    if (strcmp(preview.columnDisplayPrecisions, "0\t0") != 0)
        return fail("dataset preview precision metadata mismatch");
    if (preview.totalRowCount != 4 || preview.totalColumnCount != 3)
        return fail("dataset preview total dimensions mismatch");
    HDHDFFreeDatasetPreview(&preview);

    HDHDFDatasetPreview plot = HDHDFCopyDatasetPlotPreview(file, "/group/matrix", 2, 3, 6);
    if (plot.errorMessage != NULL)
        return fail(plot.errorMessage);
    if (strcmp(plot.text, "0\t1\t2\n6\t7\t8") != 0)
        return fail("dataset plot preview mismatch");
    if (plot.startRow != 0 || plot.rowStride != 2 || plot.rowCount != 2 || plot.columnCount != 3)
        return fail("dataset plot preview dimensions mismatch");
    if (strcmp(plot.xAxisValues, "10\t11") != 0)
        return fail("dataset plot x axis stride mismatch");
    HDHDFFreeDatasetPreview(&plot);

    HDHDFDatasetPreview plotWindow = HDHDFCopyDatasetPlotPreviewWindow(file, "/group/matrix", 1, 3, 2, 3, 6);
    if (plotWindow.errorMessage != NULL)
        return fail(plotWindow.errorMessage);
    if (strcmp(plotWindow.text, "3\t4\t5\n9\t10\t11") != 0)
        return fail("dataset plot window preview mismatch");
    if (plotWindow.startRow != 1 || plotWindow.rowStride != 2 || plotWindow.rowCount != 2 || plotWindow.columnCount != 3)
        return fail("dataset plot window dimensions mismatch");
    if (strcmp(plotWindow.xAxisValues, "10.5\t11.5") != 0)
        return fail("dataset plot window x axis stride mismatch");
    HDHDFFreeDatasetPreview(&plotWindow);

    HDHDFDatasetPreview page = HDHDFCopyDatasetPreviewWindow(file, "/group/matrix", 2, 1, 3, 3);
    if (page.errorMessage != NULL)
        return fail(page.errorMessage);
    if (strcmp(page.text, "6\t7\t8") != 0)
        return fail("dataset preview window mismatch");
    if (page.startRow != 2 || page.rowCount != 1 || page.columnCount != 3)
        return fail("dataset preview window dimensions mismatch");
    HDHDFFreeDatasetPreview(&page);

    HDHDFDatasetPreview compound = HDHDFCopyDatasetPreview(file, "/group/samples", 2, 4, 8);
    if (compound.errorMessage != NULL)
        return fail(compound.errorMessage);
    if (strcmp(compound.text, "0\t1.5\t0.25\t1\n1\t2.5\t0.5\t0.75") != 0)
        return fail("compound dataset preview mismatch");
    if (strcmp(compound.columnLabels, "sample_number\ttime\tsine\tcosine") != 0)
        return fail("compound dataset labels mismatch");
    if (strcmp(compound.columnDisplayPrecisions, "0\t17\t17\t17") != 0)
        return fail("compound dataset precision metadata mismatch");
    if (compound.startRow != 0 || compound.rowCount != 2 || compound.columnCount != 4)
        return fail("compound dataset preview dimensions mismatch");
    if (compound.totalRowCount != 3 || compound.totalColumnCount != 4)
        return fail("compound dataset preview total dimensions mismatch");
    if (strcmp(compound.xAxisLabel, "time") != 0)
        return fail("compound x axis label mismatch");
    if (strcmp(compound.xAxisValues, "10\t10.5") != 0)
        return fail("compound x axis values mismatch");
    if (strcmp(compound.xAxisSource, "sampling_rate/start_time") != 0)
        return fail("compound x axis source mismatch");
    HDHDFFreeDatasetPreview(&compound);

    HDHDFDatasetPreview scaled = HDHDFCopyDatasetPreview(file, "/scale_group/values", 3, 1, 3);
    if (scaled.errorMessage != NULL)
        return fail(scaled.errorMessage);
    if (strcmp(scaled.xAxisLabel, "time") != 0)
        return fail("dimension scale x axis label mismatch");
    if (strcmp(scaled.xAxisValues, "100\t101\t102") != 0)
        return fail("dimension scale x axis values mismatch");
    if (strcmp(scaled.xAxisSource, "dimension scale") != 0)
        return fail("dimension scale x axis source mismatch");
    HDHDFFreeDatasetPreview(&scaled);

    HDHDFDatasetPreview precise = HDHDFCopyDatasetPlotPreview(file, "/precision_group/values", 2, 1, 2);
    if (precise.errorMessage != NULL)
        return fail(precise.errorMessage);
    if (strstr(precise.text, "0.123456789012345") == NULL)
        return fail("precise dataset value lost decimal precision");
    if (strchr(precise.xAxisValues, '.') == NULL)
        return fail("precise x axis lost decimal precision");
    if (precise.xAxisDisplayPrecision < 15)
        return fail("precise x axis precision metadata mismatch");
    HDHDFFreeDatasetPreview(&precise);

    HDHDFCloseFile(file);
    remove(path);
    printf("Smoke test passed\n");
    return 0;
}
