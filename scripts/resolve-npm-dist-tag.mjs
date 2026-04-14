const ref = process.argv[2];

if (!ref) {
  console.error('Expected a Git ref argument.');
  process.exit(1);
}

const tagRefPrefix = 'refs/tags/';

if (!ref.startsWith(tagRefPrefix)) {
  console.error(`Expected a tag ref, received "${ref}".`);
  process.exit(1);
}

const versionTag = ref.slice(tagRefPrefix.length);

// Stable 8.x releases must publish with an explicit "latest" tag because npm
// still contains an accidental 10.0.0 release from an older workflow bug.
let npmTag = 'latest';

if (versionTag.includes('-alpha.')) {
  npmTag = 'next';
} else if (versionTag.startsWith('6.')) {
  npmTag = 'lts-v6';
}

process.stdout.write(npmTag);
