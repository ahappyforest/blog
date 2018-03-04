git clone git@github.com:ahappyforest/ahappyforest.github.io.git public
mv public/.git .git_public_tmp
rm -rf public
hugo --theme=even --baseUrl="http://ahappyforest.github.io"
mv .git_public_tmp public/.git
cd public
git init
git add .
git commit -m 'publish'
git remote add origin git@github.com:ahappyforest/ahappyforest.github.io.git
git push origin master --force
