# Evidence in pull requests

A designer or marketer judges a change by looking at it. A screenshot saved in a cloud container's `/tmp` never reaches them, and GitHub has no API for uploading an image into a pull request body. Use one of these, best first, and say in the pull request which one you used.

## 1. A preview link (web apps)

If the repository deploys previews per pull request (Vercel, Netlify, Cloudflare Pages, or its own), wait for the preview, drive it with the verification skill, and put the link at the top of **Before and after**. The requester can click through the real thing. Still add screenshots of the exact states you changed, using 2 below.

## 2. Images committed to the pull request branch, then removed

This works from any cloud session that can push its own branch, in private repositories too.

1. Save the images as `.agents/evidence/<branch-name>/<n>-<what>.png` (before and after as separate files; keep each under 1 MB, and use a short `.gif` or `.mp4` for motion).
2. Commit them. Note the commit's full SHA.
3. In a second commit, delete `.agents/evidence/`. Push both commits together, so the check runs only on the second.
4. Embed each image by the first commit's SHA:

   ```markdown
   ![Checkout after](https://github.com/<owner>/<repo>/blob/<sha>/.agents/evidence/<branch-name>/2-checkout-after.png?raw=true)
   ```

   Anyone who can read the repository sees the image. GitHub keeps the commit through the pull request's own ref, so the link keeps working after a squash merge.

Remove `.agents/evidence/` before the pull request merges. If the repository's CI can take one more line, fail it on `test ! -e .agents/evidence`, so evidence left behind by mistake never reaches the default branch.

Never capture real customer data, secrets, or production accounts in evidence. Use the seeded test accounts.

## 3. A CI job that captures and posts images

For surfaces a cloud container cannot run (the iOS Simulator, an accelerated Android emulator), let CI capture the images: see `templates/github/ios-snapshots.yml` and [verification drivers](verification-drivers.md#proof-without-a-device). Link the job's artifacts and the comment it posts.

## 4. In the conversation

Also hand the images to the person directly when your agent can send files into the chat (Claude Code on the web and in the Claude app can). The pull request is the record; the chat is where they are looking now.

## If none is possible

Say so plainly in **How it was checked**: what was verified (tests, a build), what was not, and where it will be verified. Never describe a screenshot you did not take.
