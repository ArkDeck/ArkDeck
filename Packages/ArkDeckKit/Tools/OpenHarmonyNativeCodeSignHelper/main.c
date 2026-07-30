/*
 * ArkDeck OpenHarmony native-library code-sign enable helper.
 *
 * This intentionally mirrors the bounded V1 ELF sign-block parser used by
 * OpenHarmony security_code_signature. It accepts only an already signed ELF;
 * it does not create signatures, contact a signing service, or broaden trust.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fsverity.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#define ARKDECK_MAX_SIGN_BLOCK (16U * 1024U * 1024U)
#define ARKDECK_SIGN_HEADER_SIZE 32U
#define ARKDECK_SIGN_INFO_PREFIX_SIZE 264U
#define ARKDECK_MAX_SIGNATURE_SIZE (4U * 1024U * 1024U)

static const uint8_t ELF_MAGIC[4] = {0x7f, 0x45, 0x4c, 0x46};
static const uint8_t SIGN_MAGIC[16] = {
    0x65, 0x6c, 0x66, 0x20, 0x73, 0x69, 0x67, 0x6e,
    0x20, 0x62, 0x6c, 0x6f, 0x63, 0x6b, 0x20, 0x20};
static const uint8_t SIGN_VERSION[4] = {0x31, 0x30, 0x30, 0x30};

struct __attribute__((packed)) elf_block_header {
  uint16_t type;
  uint16_t tag;
  uint32_t size;
  uint32_t offset;
};

struct __attribute__((packed)) elf_sign_header {
  uint8_t magic[16];
  uint8_t version[4];
  uint32_t block_size;
  uint32_t block_num;
  uint8_t reserved[4];
};

struct __attribute__((packed)) elf_sign_info {
  uint32_t type;
  uint32_t length;
  uint8_t version;
  uint8_t hash_algorithm;
  uint8_t log_block_size;
  uint8_t salt_size;
  uint32_t sign_size;
  uint64_t data_size;
  uint8_t root_hash[64];
  uint8_t salt[32];
  uint32_t flags;
  uint8_t reserved_1[4];
  uint64_t tree_offset;
  uint8_t reserved_2[127];
  uint8_t cs_version;
  uint8_t signature[];
};

struct parsed_sign_block {
  uint8_t *storage;
  struct code_sign_enable_arg argument;
};

static int read_exact(int fd, void *buffer, size_t size, off_t offset) {
  uint8_t *cursor = (uint8_t *)buffer;
  size_t remaining = size;
  while (remaining > 0) {
    ssize_t count = pread(fd, cursor, remaining, offset);
    if (count <= 0) {
      return -1;
    }
    cursor += (size_t)count;
    remaining -= (size_t)count;
    offset += count;
  }
  return 0;
}

static int parse_sign_block(int fd, off_t file_size,
                            struct parsed_sign_block *parsed) {
  uint8_t elf_magic[sizeof(ELF_MAGIC)];
  struct elf_sign_header header;
  uint8_t *block = NULL;
  uint32_t sign_info_offset = 0;

  memset(parsed, 0, sizeof(*parsed));
  if (file_size < (off_t)ARKDECK_SIGN_HEADER_SIZE ||
      read_exact(fd, elf_magic, sizeof(elf_magic), 0) != 0 ||
      memcmp(elf_magic, ELF_MAGIC, sizeof(ELF_MAGIC)) != 0 ||
      read_exact(fd, &header, sizeof(header),
                 file_size - (off_t)sizeof(header)) != 0 ||
      memcmp(header.magic, SIGN_MAGIC, sizeof(SIGN_MAGIC)) != 0 ||
      memcmp(header.version, SIGN_VERSION, sizeof(SIGN_VERSION)) != 0 ||
      header.block_num < 1 || header.block_num > 2 ||
      header.block_size < header.block_num * sizeof(struct elf_block_header) ||
      header.block_size > ARKDECK_MAX_SIGN_BLOCK ||
      (off_t)header.block_size > file_size - (off_t)sizeof(header)) {
    return -1;
  }

  block = (uint8_t *)malloc(header.block_size);
  if (block == NULL ||
      read_exact(fd, block, header.block_size,
                 file_size - (off_t)sizeof(header) -
                     (off_t)header.block_size) != 0) {
    free(block);
    return -1;
  }

  for (uint32_t index = 0; index < header.block_num; ++index) {
    const struct elf_block_header *candidate =
        (const struct elf_block_header *)(block +
                                         index * sizeof(*candidate));
    if (candidate->type == 3) {
      sign_info_offset = candidate->offset;
      break;
    }
  }
  if (sign_info_offset == 0 ||
      sign_info_offset > header.block_size - 8U) {
    free(block);
    return -1;
  }

  const uint8_t *merkle = block + sign_info_offset;
  uint32_t merkle_type;
  uint32_t merkle_length;
  memcpy(&merkle_type, merkle, sizeof(merkle_type));
  memcpy(&merkle_length, merkle + 4, sizeof(merkle_length));
  if (merkle_type != 2 ||
      merkle_length > header.block_size - sign_info_offset - 8U) {
    free(block);
    return -1;
  }

  uint64_t raw_info_offset =
      (uint64_t)sign_info_offset + 8U + (uint64_t)merkle_length;
  if (raw_info_offset > header.block_size ||
      header.block_size - (uint32_t)raw_info_offset <
          ARKDECK_SIGN_INFO_PREFIX_SIZE) {
    free(block);
    return -1;
  }
  const struct elf_sign_info *info =
      (const struct elf_sign_info *)(block + (uint32_t)raw_info_offset);
  uint32_t remaining = header.block_size - (uint32_t)raw_info_offset;
  if (info->type != 1 || info->version != 1 ||
      info->hash_algorithm != FS_VERITY_HASH_ALG_SHA256 ||
      info->log_block_size != 12 || info->salt_size > sizeof(info->salt) ||
      info->sign_size == 0 || info->sign_size > ARKDECK_MAX_SIGNATURE_SIZE ||
      info->length > remaining - 8U ||
      ARKDECK_SIGN_INFO_PREFIX_SIZE + info->sign_size >
          8U + info->length ||
      info->data_size == 0 ||
      info->data_size !=
          (uint64_t)(file_size - (off_t)sizeof(header) -
                     (off_t)header.block_size) ||
      info->tree_offset >= (uint64_t)file_size || info->cs_version != 1) {
    free(block);
    return -1;
  }

  parsed->storage = block;
  memset(&parsed->argument, 0, sizeof(parsed->argument));
  parsed->argument.version = 1;
  parsed->argument.cs_version = info->cs_version;
  parsed->argument.hash_algorithm = info->hash_algorithm;
  parsed->argument.block_size = 1U << info->log_block_size;
  parsed->argument.salt_ptr = (uintptr_t)info->salt;
  parsed->argument.salt_size = info->salt_size;
  parsed->argument.sig_size = info->sign_size;
  parsed->argument.sig_ptr = (uintptr_t)info->signature;
  parsed->argument.data_size = info->data_size;
  parsed->argument.tree_offset = info->tree_offset;
  parsed->argument.root_hash_ptr = (uintptr_t)info->root_hash;
  parsed->argument.flags = info->flags;
  return 0;
}

static int measure_verity(int fd, char *digest_hex, size_t digest_hex_size) {
  uint8_t storage[sizeof(struct fsverity_digest) + 64];
  struct fsverity_digest *measured = (struct fsverity_digest *)storage;
  memset(storage, 0, sizeof(storage));
  measured->digest_size = 64;
  if (ioctl(fd, FS_IOC_MEASURE_VERITY, measured) != 0 ||
      measured->digest_algorithm != FS_VERITY_HASH_ALG_SHA256 ||
      measured->digest_size != 32 || digest_hex_size < 65) {
    return -1;
  }
  for (uint16_t index = 0; index < measured->digest_size; ++index) {
    (void)snprintf(digest_hex + index * 2, digest_hex_size - index * 2,
                   "%02x", measured->digest[index]);
  }
  digest_hex[64] = '\0';
  return 0;
}

static int enable_code_sign_internal(const char *path, char *digest,
                                     size_t digest_size) {
  struct stat metadata;
  struct parsed_sign_block parsed;
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0 || fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      metadata.st_size <= 0) {
    if (fd >= 0) {
      close(fd);
    }
    return 20;
  }

  if (measure_verity(fd, digest, digest_size) == 0) {
    close(fd);
    return 0;
  }
  if (parse_sign_block(fd, metadata.st_size, &parsed) != 0) {
    close(fd);
    return 21;
  }
  if (ioctl(fd, FS_IOC_ENABLE_CODE_SIGN, &parsed.argument) != 0) {
    free(parsed.storage);
    close(fd);
    return 22;
  }
  free(parsed.storage);
  if (measure_verity(fd, digest, digest_size) != 0) {
    close(fd);
    return 23;
  }
  close(fd);
  return 0;
}

static int enable_code_sign(const char *path) {
  char digest[65];
  int result = enable_code_sign_internal(path, digest, sizeof(digest));
  if (result != 0) {
    fprintf(stderr, "ARKDECK_CODE_SIGN_ERROR stage=enable code=%d errno=%d\n",
            result, errno);
    return result;
  }
  printf("ARKDECK_CODE_SIGN_ENABLED sha256:%s\n", digest);
  return 0;
}

static int verify_code_sign(const char *path) {
  struct stat metadata;
  char digest[65];
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0 || fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      measure_verity(fd, digest, sizeof(digest)) != 0) {
    if (fd >= 0) {
      close(fd);
    }
    fprintf(stderr, "ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=%d\n",
            errno);
    return 30;
  }
  printf("ARKDECK_CODE_SIGN_VERIFIED sha256:%s\n", digest);
  close(fd);
  return 0;
}

static int copy_for_publish(const char *source_path, const char *target_path,
                            const char *prepared_path) {
  struct stat source_metadata;
  struct stat target_metadata;
  uint8_t buffer[64U * 1024U];
  int source = -1;
  int target = -1;
  int prepared = -1;
  int result = 40;

  source = open(source_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  target = open(target_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (source < 0 || target < 0 || fstat(source, &source_metadata) != 0 ||
      fstat(target, &target_metadata) != 0 ||
      !S_ISREG(source_metadata.st_mode) || !S_ISREG(target_metadata.st_mode) ||
      source_metadata.st_size < 64 ||
      source_metadata.st_size > (off_t)(64U * 1024U * 1024U +
                                         ARKDECK_MAX_SIGN_BLOCK)) {
    goto cleanup;
  }
  (void)unlink(prepared_path);
  prepared = open(prepared_path,
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (prepared < 0) {
    result = 41;
    goto cleanup;
  }
  while (1) {
    ssize_t count = read(source, buffer, sizeof(buffer));
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0) {
      result = 42;
      goto cleanup;
    }
    if (count == 0) {
      break;
    }
    ssize_t offset = 0;
    while (offset < count) {
      ssize_t written = write(prepared, buffer + offset, (size_t)(count - offset));
      if (written < 0 && errno == EINTR) {
        continue;
      }
      if (written <= 0) {
        result = 43;
        goto cleanup;
      }
      offset += written;
    }
  }
  if (fchown(prepared, target_metadata.st_uid, target_metadata.st_gid) != 0 ||
      fchmod(prepared, target_metadata.st_mode & 07777) != 0 ||
      fsync(prepared) != 0) {
    result = 44;
    goto cleanup;
  }
  result = 0;

cleanup:
  if (prepared >= 0) {
    close(prepared);
  }
  if (target >= 0) {
    close(target);
  }
  if (source >= 0) {
    close(source);
  }
  if (result != 0) {
    (void)unlink(prepared_path);
  }
  return result;
}

static int publish_code_signed(const char *source_path, const char *target_path,
                               const char *prepared_path) {
  char enabled_digest[65];
  char published_digest[65];
  int result = copy_for_publish(source_path, target_path, prepared_path);
  if (result != 0) {
    fprintf(stderr, "ARKDECK_CODE_SIGN_ERROR stage=prepare code=%d errno=%d\n",
            result, errno);
    return result;
  }
  result = enable_code_sign_internal(prepared_path, enabled_digest,
                                     sizeof(enabled_digest));
  if (result != 0) {
    fprintf(stderr, "ARKDECK_CODE_SIGN_ERROR stage=enable code=%d errno=%d\n",
            result, errno);
    (void)unlink(prepared_path);
    return result;
  }
  if (rename(prepared_path, target_path) != 0) {
    result = 45;
    fprintf(stderr, "ARKDECK_CODE_SIGN_ERROR stage=rename code=%d errno=%d\n",
            result, errno);
    (void)unlink(prepared_path);
    return result;
  }
  int target = open(target_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (target < 0 ||
      measure_verity(target, published_digest, sizeof(published_digest)) != 0 ||
      strcmp(enabled_digest, published_digest) != 0) {
    if (target >= 0) {
      close(target);
    }
    result = 46;
    fprintf(stderr, "ARKDECK_CODE_SIGN_ERROR stage=readback code=%d errno=%d\n",
            result, errno);
    return result;
  }
  close(target);
  printf("ARKDECK_CODE_SIGN_PUBLISHED sha256:%s\n", published_digest);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "enable") == 0) {
    return enable_code_sign(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "verify") == 0) {
    return verify_code_sign(argv[2]);
  }
  if (argc == 5 && strcmp(argv[1], "publish") == 0) {
    return publish_code_signed(argv[2], argv[3], argv[4]);
  }
  return 64;
}
