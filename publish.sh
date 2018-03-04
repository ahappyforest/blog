mv public/.git .git_public_tmp
rm -rf public
hugo --theme=even --baseUrl="http://ahappyforest.github.io"
mv .git_public_tmp public/.git
cd public
git add .
git commit -m 'publish'
git push origin master --force
