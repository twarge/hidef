// SPDX-FileCopyrightText: 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0

#include <hdf5.h>
#include <stdio.h>

static int write_string_attribute(hid_t object, const char *name, const char *value) {
    hid_t dataspace = H5Screate(H5S_SCALAR);
    hid_t string_type = H5Tcopy(H5T_C_S1);
    if (dataspace < 0 || string_type < 0) {
        return -1;
    }

    if (H5Tset_size(string_type, H5T_VARIABLE) < 0 ||
        H5Tset_cset(string_type, H5T_CSET_UTF8) < 0) {
        H5Tclose(string_type);
        H5Sclose(dataspace);
        return -1;
    }

    hid_t attribute = H5Acreate2(object, name, string_type, dataspace, H5P_DEFAULT, H5P_DEFAULT);
    if (attribute < 0) {
        H5Tclose(string_type);
        H5Sclose(dataspace);
        return -1;
    }

    const char *attribute_value = value;
    int status = H5Awrite(attribute, string_type, &attribute_value);
    H5Aclose(attribute);
    H5Tclose(string_type);
    H5Sclose(dataspace);
    return status;
}

int main(int argc, char **argv) {
    const char *output_path = argc > 1 ? argv[1] : "Resources/Demo/demo.h5";

    hid_t file = H5Fcreate(output_path, H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
    if (file < 0) {
        fprintf(stderr, "Could not create %s\n", output_path);
        return 1;
    }

    if (write_string_attribute(file, "description", "Compact demonstration HDF5 file") < 0 ||
        write_string_attribute(file, "author", "Demo Script") < 0) {
        H5Fclose(file);
        return 1;
    }

    hid_t group = H5Gcreate2(file, "timeseries", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (group < 0) {
        H5Fclose(file);
        return 1;
    }

    hsize_t dimensions[2] = {10, 10};
    hid_t dataspace = H5Screate_simple(2, dimensions, NULL);
    hid_t properties = H5Pcreate(H5P_DATASET_CREATE);
    if (dataspace < 0 || properties < 0) {
        H5Gclose(group);
        H5Fclose(file);
        return 1;
    }

    if (H5Pset_chunk(properties, 2, dimensions) < 0 || H5Pset_deflate(properties, 4) < 0) {
        H5Pclose(properties);
        H5Sclose(dataspace);
        H5Gclose(group);
        H5Fclose(file);
        return 1;
    }

    hid_t dataset = H5Dcreate2(
        group,
        "sensor_data",
        H5T_NATIVE_INT,
        dataspace,
        H5P_DEFAULT,
        properties,
        H5P_DEFAULT
    );
    if (dataset < 0) {
        H5Pclose(properties);
        H5Sclose(dataspace);
        H5Gclose(group);
        H5Fclose(file);
        return 1;
    }

    int values[100];
    for (int index = 0; index < 100; index++) {
        values[index] = index;
    }

    if (H5Dwrite(dataset, H5T_NATIVE_INT, H5S_ALL, H5S_ALL, H5P_DEFAULT, values) < 0 ||
        write_string_attribute(dataset, "units", "Celsius") < 0 ||
        write_string_attribute(dataset, "sensor_id", "A-992") < 0) {
        H5Dclose(dataset);
        H5Pclose(properties);
        H5Sclose(dataspace);
        H5Gclose(group);
        H5Fclose(file);
        return 1;
    }

    H5Dclose(dataset);
    H5Pclose(properties);
    H5Sclose(dataspace);
    H5Gclose(group);
    H5Fclose(file);

    printf("File '%s' created successfully.\n", output_path);
    return 0;
}
