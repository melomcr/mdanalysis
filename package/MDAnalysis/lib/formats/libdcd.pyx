# -*- Mode: python; tab-width: 4; indent-tabs-mode:nil; coding:utf-8 -*-
# vim: tabstop=4 expandtab shiftwidth=4 softtabstop=4
#
# MDAnalysis --- http://www.MDAnalysis.org
# Copyright (c) 2006-2015 Naveen Michaud-Agrawal, Elizabeth J. Denning, Oliver
# Beckstein and contributors (see AUTHORS for the full list)
#
# Released under the GNU Public Licence, v2 or any higher version
#
# Please cite your use of MDAnalysis in published work:
#
# N. Michaud-Agrawal, E. J. Denning, T. B. Woolf, and O. Beckstein.
# MDAnalysis: A Toolkit for the Analysis of Molecular Dynamics Simulations.
# J. Comput. Chem. 32 (2011), 2319--2327, doi:10.1002/jcc.21787
#

from os import path
import numpy as np
from collections import namedtuple
import six
import string
import sys

cimport numpy as np
from libc.stdio cimport SEEK_SET, SEEK_CUR, SEEK_END
from libc.stdint cimport uintptr_t
from libc.stdlib cimport free

_whence_vals = {"FIO_SEEK_SET": SEEK_SET,
                "FIO_SEEK_CUR": SEEK_CUR,
                "FIO_SEEK_END": SEEK_END}

# Tell cython about the off_t type. It doesn't need to match exactly what is
# defined since we don't expose it to python but the cython compiler needs to
# know about it.
cdef extern from 'sys/types.h':
    ctypedef int off_t

ctypedef int fio_fd;
ctypedef off_t fio_size_t

ctypedef np.float32_t FLOAT_T
ctypedef np.float64_t DOUBLE_T
FLOAT = np.float32
DOUBLE = np.float64

cdef enum:
    FIO_READ = 0x01
    FIO_WRITE = 0x02

cdef enum:
    DCD_IS_CHARMM       = 0x01
    DCD_HAS_4DIMS       = 0x02
    DCD_HAS_EXTRA_BLOCK = 0x04

DCD_ERRORS = {
    0: 'No Problem',
    -1: 'Normal EOF',
    -2: 'DCD file does not exist',
    -3: 'Open of DCD file failed',
    -4: 'read call on DCD file failed',
    -5: 'premature EOF found in DCD file',
    -6: 'format of DCD file is wrong',
    -7: 'output file already exiss',
    -8: 'malloc failed'
}

cdef extern from 'include/fastio.h':
    int fio_open(const char *filename, int mode, fio_fd *fd)
    int fio_fclose(fio_fd fd)
    fio_size_t fio_ftell(fio_fd fd)
    fio_size_t fio_fseek(fio_fd fd, fio_size_t offset, int whence)

cdef extern from 'include/readdcd.h':
    int read_dcdheader(fio_fd fd, int *natoms, int *nsets, int *istart,
                       int *nsavc, double *delta, int *nfixed, int **freeind,
                       float **fixedcoords, int *reverse_endian, int *charmm,
                       char **remarks, int *len_remarks)
    void close_dcd_read(int *freeind, float *fixedcoords)
    int read_dcdstep(fio_fd fd, int natoms, float *X, float *Y, float *Z,
                     double *unitcell, int num_fixed,
                     int first, int *indexes, float *fixedcoords,
                     int reverse_endian, int charmm)
    int read_dcdsubset(fio_fd fd, int natoms, int lowerb, int upperb,
                     float *X, float *Y, float *Z,
                     double *unitcell, int num_fixed,
                     int first, int *indexes, float *fixedcoords,
                     int reverse_endian, int charmm)
    int write_dcdheader(fio_fd fd, const char *remarks, int natoms, 
                   int istart, int nsavc, double delta, int with_unitcell, 
                   int charmm);
    int write_dcdstep(fio_fd fd, int curframe, int curstep, 
			 int natoms, const float *x, const float *y, const float *z,
			 const double *unitcell, int charmm);

DCDFrame = namedtuple('DCDFrame', 'x unitcell')

cdef class DCDFile:
    cdef fio_fd fp
    cdef readonly fname
    cdef int istart
    cdef int nsavc
    cdef double delta
    cdef int natoms
    cdef int nfixed
    cdef int *freeind
    cdef float *fixedcoords
    cdef int reverse_endian
    cdef int charmm
    cdef remarks
    cdef str mode
    cdef readonly int n_dims
    cdef readonly int n_frames
    cdef bint b_read_header
    cdef int current_frame
    cdef readonly int _firstframesize
    cdef readonly int _framesize
    cdef readonly int _header_size
    cdef int is_open
    cdef int reached_eof
    cdef int wrote_header

    def __cinit__(self, fname, mode='r'):
        self.fname = fname.encode('utf-8')
        self.natoms = 0
        self.is_open = False
        self.wrote_header = False
        self.open(self.fname, mode)

    def __dealloc__(self):
        self.close()

    def __enter__(self):
        """Support context manager"""
        if not self.is_open:
            self.open(self.fname, self.mode)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Support context manager"""
        self.close()
        # always propagate exceptions forward
        return False

    def __iter__(self):
        self.close()
        self.open(self.fname, self.mode)
        return self

    def __next__(self):
        if self.reached_eof:
            raise StopIteration
        return self.read()

    def __len__(self):
        if not self.is_open:
            raise IOError('No file currently opened')
        return self.n_frames

    def tell(self):
        return self.current_frame

    def open(self, filename, mode='r'):
        if self.is_open:
            self.close()

        if mode == 'r':
            fio_mode = FIO_READ
        elif mode == 'w':
            fio_mode = FIO_WRITE
        else:
            raise IOError("unkown mode '{}', use either r or w".format(mode))
        self.mode = str(mode)

        ok = fio_open(self.fname, fio_mode, <fio_fd*> &self.fp)
        if ok != 0:
            raise IOError("couldn't open file: {}\n"
                          "ErrorCode: {}".format(self.fname, ok))
        self.is_open = True
        self.current_frame = 0
        self.reached_eof = False
        self.wrote_header = False
        # Has to come last since it checks the reached_eof flag
        if self.mode == 'r':
            self.remarks = self._read_header()

    def close(self):
        if self.is_open:
            # In case there are fixed atoms we should free the memory again.
            # Both pointers are guaranted to be non NULL if either one is.
            if self.freeind != NULL:
                close_dcd_read(self.freeind, self.fixedcoords);

            ok = fio_fclose(self.fp)
            self.is_open = False
            if ok != 0:
                raise IOError("couldn't close file: {}\n"
                              "ErrorCode: {}".format(self.fname, ok))


    def _read_header(self):
        if not self.is_open:
            raise IOError("No file open")

        cdef char* c_remarks
        cdef int len_remarks = 0
        cdef int nsets

        ok = read_dcdheader(self.fp, &self.natoms, &nsets, &self.istart,
                            &self.nsavc, &self.delta, &self.nfixed, &self.freeind,
                            &self.fixedcoords, &self.reverse_endian,
                            &self.charmm, &c_remarks, &len_remarks)
        if ok != 0:
            raise IOError("Reading DCD header failed: {}".format(DCD_ERRORS[ok]))

        if c_remarks != NULL:
            py_remarks = <bytes> c_remarks[:len_remarks]
            free(c_remarks)
        else:
            py_remarks = ""

        self.n_dims = 3 if not self.charmm & DCD_HAS_4DIMS else 4
        self.n_frames = self._estimate_n_frames()
        self.b_read_header = True

        # make sure fixed atoms have been read
        try:
            self.read()
            self.seek(0)
        except:
            # if this fails the file is empty. Set flag and warn using during read
            if self.n_frames != 0:
                raise IOError("DCD is corrupted")

        if sys.version_info[0] < 3:
            py_remarks = unicode(py_remarks, 'ascii', "ignore")
            py_remarks = str(py_remarks.encode('ascii', 'ignore'))
        else:
            if isinstance(py_remarks, bytes):
                py_remarks = py_remarks.decode('ascii', 'ignore')

        py_remarks = "".join(s for s in py_remarks if s in string.printable)

        return py_remarks

    def _estimate_n_frames(self):
        extrablocksize = 48 + 8 if self.charmm & DCD_HAS_EXTRA_BLOCK else 0
        self._firstframesize = (self.natoms + 2) * self.n_dims * sizeof(float) + extrablocksize
        self._framesize = ((self.natoms - self.nfixed + 2) * self.n_dims * sizeof(float) +
                          extrablocksize)
        filesize = path.getsize(self.fname)
        # It's safe to use ftell, even though ftell returns a long, because the
        # header size is < 4GB.
        self._header_size = fio_ftell(self.fp)
        nframessize = filesize - self._header_size - self._firstframesize
        return nframessize / self._framesize + 1

    @property
    def is_periodic(self):
          return bool((self.charmm & DCD_IS_CHARMM) and
                      (self.charmm & DCD_HAS_EXTRA_BLOCK))

    def seek(self, frame):
        """Seek to Frame.

        Please note that this function will generate internal file offsets if
        they haven't been set before. For large file this means the first seek
        can be very slow. Later seeks will be very fast.

        Parameters
        ----------
        frame : int
            seek the file to given frame

        Raises
        ------
        IOError
            If you seek for more frames than are available or if the
            seek fails (the low-level system error is reported).
        """
        if frame >= self.n_frames:
            raise IOError('Trying to seek over max number of frames')
        self.reached_eof = False

        cdef fio_size_t offset
        if frame == 0:
            offset = self._header_size
        else:
            offset = self._header_size + self._firstframesize + self._framesize * (frame - 1)

        ok = fio_fseek(self.fp, offset, _whence_vals["FIO_SEEK_SET"])
        if ok != 0:
            raise IOError("DCD seek failed with system errno={}".format(ok))
        self.current_frame = frame

    @property
    def header(self):
        return {'natoms': self.natoms,
                'istart': self.istart,
                'nsavc': self.nsavc,
                'delta': self.delta,
                'charmm': self.charmm,
                'remarks': self.remarks}

    def write_header(self, remarks, natoms, istart,
                     nsavc, delta,
                     charmm):
        """write DCD header

        Parameters
        ----------
        remarks : str
            remarks of DCD file. Shouldn't be more then 240 characters (ASCII)
        natoms : int
            number of atoms to write
        istart : int
        nsavc : int
        delta : float
        charmm : int
        """
        if not self.is_open:
            raise IOError("No file open")
        if not self.mode=='w':
            raise IOError("Incorrect file mode for writing.")
        if self.wrote_header:
            raise IOError("Header already written")

        cdef int len_remarks = 0
        cdef int with_unitcell = 1

        if isinstance(remarks, six.string_types):
            try:
                remarks = bytearray(remarks, 'ascii')
            except UnicodeDecodeError:
                remarks = bytearray(remarks)

        ok = write_dcdheader(self.fp, remarks, natoms, istart,
                             nsavc, delta, with_unitcell,
                             charmm)
        if ok != 0:
            raise IOError("Writing DCD header failed: {}".format(DCD_ERRORS[ok]))

        self.charmm = charmm
        self.natoms = natoms
        self.wrote_header = True

    def write(self, xyz,  box):
        """write one frame into DCD file.

        Parameters
        ----------
        xyz : array_like, shape=(natoms, 3)
            cartesion coordinates
        box : array_like, shape=(6)
            Box vectors for this frame
        step : int
            current step number, 1 indexed
        time : float
            current time
        natoms : int
            number of atoms in frame

        Raises
        ------
        IOError
        """
        if not self.is_open:
            raise IOError("No file open")
        if self.mode != 'w':
            raise IOError('File opened in mode: {}. Writing only allowed '
                          'in mode "w"'.format('self.mode'))
        if len(box) != 6:
            raise ValueError("box size is wrong should be 6, got: {}".format(box.size))
        if not self.wrote_header:
            raise IOError("write header first before frames can be written")
        xyz = np.asarray(xyz, order='F', dtype=np.float32)
        if xyz.shape != (self.natoms, 3):
            raise ValueError("xyz shape is wrong should be (natoms, 3), got:".format(xyz.shape))

        cdef DOUBLE_T[::1] c_box = np.asarray(box, order='C', dtype=np.float64)
        cdef FLOAT_T[::1] x = xyz[:, 0]
        cdef FLOAT_T[::1] y = xyz[:, 1]
        cdef FLOAT_T[::1] z = xyz[:, 2]

        step = self.istart + self.current_frame * self.nsavc
        ok = write_dcdstep(self.fp, self.current_frame + 1, step,
                           self.natoms, <FLOAT_T*> &x[0],
                           <FLOAT_T*> &y[0], <FLOAT_T*> &z[0],
                           <DOUBLE_T*> &c_box[0], self.charmm)

        self.current_frame += 1

    def read(self):
        if self.reached_eof:
            raise IOError('Reached last frame in DCD, seek to 0')
        if not self.is_open:
            raise IOError("No file open")
        if self.mode != 'r':
            raise IOError('File opened in mode: {}. Reading only allow '
                               'in mode "r"'.format('self.mode'))
        if self.n_frames == 0:
            raise IOError("opened empty file. No frames are saved")

        cdef np.ndarray xyz = np.empty((self.natoms, self.ndims), dtype=FLOAT, order='F')
        cdef np.ndarray unitcell = np.empty(6, dtype=DOUBLE)
        unitcell[0] = unitcell[2] = unitcell[5] = 0.0;
        unitcell[4] = unitcell[3] = unitcell[1] = 90.0;

        cdef FLOAT_T[::1] x = xyz[:, 0]
        cdef FLOAT_T[::1] y = xyz[:, 1]
        cdef FLOAT_T[::1] z = xyz[:, 2]

        first_frame = self.current_frame == 0
        ok = read_dcdstep(self.fp, self.natoms,
                          <FLOAT_T*> &x[0],
                          <FLOAT_T*> &y[0], <FLOAT_T*> &z[0],
                          <DOUBLE_T*> unitcell.data, self.nfixed, first_frame,
                          self.freeind, self.fixedcoords,
                          self.reverse_endian, self.charmm)
        if ok != 0 and ok != -4:
            raise IOError("Reading DCD header failed: {}".format(DCD_ERRORS[ok]))

        # we couldn't read any more frames.
        if ok == -4:
            self.reached_eof = True
            raise StopIteration

        self.current_frame += 1
        return DCDFrame(xyz, unitcell)

    def read_nframes(self, n):

        xyz = np.empty((n, self.natoms, self.ndims))
        box = np.empty((n, 6))
        cdef int i

        for i in range(n):
            f = self.read()
            xyz[i] = f.xyz
            box[i] = f.unitcell

        return DCDFrame(xyz, box)
